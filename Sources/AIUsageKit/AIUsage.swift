import CodexBarCore
import Foundation

/// 取各家 AI 订阅的真实用量。底层是 CodexBarCore，这里做四件事：
/// 1. 每家走哪条取数路径写死（见 `route(for:)`），不碰浏览器 Cookie、不读 Claude Code 的钥匙串；
/// 2. 跨进程共享缓存 + Per-Provider `flock` 互斥锁 + `DistributedNotificationCenter` 广播，多个 App 同时运行时只刷一次；
/// 3. 把 CodexBar 的数据整理成统一的 `UsageWindow` 列表；
/// 4. 屏蔽 CodexBarCore 的接口变化 —— 它升级改了签名，只改这个文件。
public enum AIUsage {
    /// 跨进程共享缓存默认有效期（秒）：180 秒（3 分钟）。
    /// 当多个 App 各自定时轮询时，只要距离上一次任一进程成功写入未超过 `maxAge`（且无窗口刚过 `resetsAt`），直接 0ms 复用磁盘缓存。
    public static let defaultCacheMaxAge: TimeInterval = 180

    /// 当任一进程更新了某一家配额的共享缓存时，通过 `DistributedNotificationCenter.default()` 广播此通知。
    /// `notification.object` 为 `provider.rawValue`（如 `"claude"` / `"antigravity"` / `"grok"`）。
    public static var didUpdateNotification: Notification.Name {
        SharedCache.didUpdateNotification
    }

    /// 跨进程日志文件位置：`~/Library/Caches/AIUsageKit/logs/usage.log`。
    public static var logFileURL: URL {
        UsageLogger.defaultLogFileURL
    }

    // MARK: - 同步读取跨进程缓存（App 启动首帧秒开用）

    /// 无锁同步读取指定厂商最近一次跨进程缓存快照（不含 `accountEmail`）。
    public static func cached(_ provider: AIProvider) -> ProviderUsage? {
        SharedCache.readRecord(for: provider)?.toProviderUsage()
    }

    /// 无锁同步读取多家厂商最近一次跨进程缓存快照。
    public static func cachedAll(_ providers: [AIProvider] = AIProvider.allCases) -> [AIProvider: ProviderUsage] {
        var out: [AIProvider: ProviderUsage] = [:]
        for provider in providers {
            if let usage = Self.cached(provider) {
                out[provider] = usage
            }
        }
        return out
    }

    /// 监听本机任何进程（含其他 App 或 CLI）写入的新配额快照。
    ///
    /// - Parameters:
    ///   - providers: 当前 App 关心的厂商集合（默认全部）。不在此集合内的通知会被直接忽略，实现按需松耦合订阅。
    ///   - handler: 在 `@MainActor` 上回调最新写入磁盘的 `(AIProvider, ProviderUsage)`。
    /// - Returns: 观察者凭据。调用方需持有该返回值；要停止监听时传给 `AIUsage.removeObserver(_:)`。
    public static func observeUpdates(
        for providers: Set<AIProvider> = Set(AIProvider.allCases),
        handler: @escaping @MainActor @Sendable (AIProvider, ProviderUsage) -> Void
    ) -> any NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: SharedCache.didUpdateNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let raw = notification.object as? String,
                  let provider = AIProvider(rawValue: raw),
                  providers.contains(provider),
                  let usage = SharedCache.readRecord(for: provider)?.toProviderUsage()
            else { return }
            UsageLogger.log(
                provider,
                event: "NOTIFY_RECV",
                fields: [("windows", UsageLogger.windowsSummary(usage.windows))]
            )
            Task { @MainActor in
                handler(provider, usage)
            }
        }
    }

    /// 移除由 `observeUpdates` 注册的跨进程通知观察者。
    public static func removeObserver(_ token: any NSObjectProtocol) {
        DistributedNotificationCenter.default().removeObserver(token)
    }

    // MARK: - 异步取数（带跨进程缓存与 flock 单飞）

    /// 取一家的用量。
    ///
    /// 包含跨进程协同与进程安全保护：
    /// - **无锁快路**：若 `maxAge > 0` 且 `~/Library/Caches/AIUsageKit/v1/<provider>.json` 在有效期内且无窗口刚过重置时间，0ms 直接返回。
    /// - **同进程合并 + 跨进程 `flock` 单飞**：多个 App 同时到期或同时手动强刷（`maxAge = 0`）时，只有一个进程会真正启动 CLI，
    ///   其余进程在等锁完成后通过 Double-Check 直接拿到刚写好的新快照。
    /// - **超时与子进程清理**：到点一定返回超时错误，并清理本次期间启动的该厂商子进程组；每次真实取数前清掉运行超过 10 分钟的残留子进程。
    ///
    /// - Parameters:
    ///   - provider: 目标厂商。
    ///   - maxAge: 允许复用跨进程缓存的最大秒数（默认 `180` 秒；传 `0` 则强制穿透旧缓存，但仍与同时在刷的其他进程合并单飞）。
    ///   - timeout: 单次超时秒数（默认 `60` 秒）。
    public static func fetch(
        _ provider: AIProvider,
        maxAge: TimeInterval = defaultCacheMaxAge,
        timeout: TimeInterval = 60
    ) async throws -> ProviderUsage {
        try await Self.fetchCoordinated(
            provider,
            maxAge: maxAge,
            timeout: timeout,
            baseDirectory: nil,
            liveFetcher: { try await Self.fetchLiveWithRetry(provider, timeout: timeout, baseDirectory: nil) }
        )
    }

    /// 并发取多家。单家失败不影响其他家。
    public static func fetchAll(
        _ providers: [AIProvider] = AIProvider.allCases,
        maxAge: TimeInterval = defaultCacheMaxAge,
        timeout: TimeInterval = 60
    ) async -> [AIProvider: Result<ProviderUsage, AIUsageError>] {
        await withTaskGroup(of: (AIProvider, Result<ProviderUsage, AIUsageError>).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return (provider, .success(try await self.fetch(provider, maxAge: maxAge, timeout: timeout)))
                    } catch let error as AIUsageError {
                        return (provider, .failure(error))
                    } catch {
                        return (provider, .failure(AIUsageError(provider: provider, message: error.localizedDescription)))
                    }
                }
            }
            var results: [AIProvider: Result<ProviderUsage, AIUsageError>] = [:]
            for await (provider, result) in group {
                results[provider] = result
            }
            return results
        }
    }

    // MARK: - 协调状态机（支持注入自定义目录与桩函数以便单元测试）

    static func fetchCoordinated(
        _ provider: AIProvider,
        maxAge: TimeInterval,
        timeout: TimeInterval,
        baseDirectory: URL?,
        liveFetcher: @Sendable @escaping () async throws -> ProviderUsage
    ) async throws -> ProviderUsage {
        let requestStart = Date()
        UsageLogger.log(
            provider,
            event: "FETCH_START",
            fields: [
                ("maxAge", String(format: "%.0fs", maxAge)),
                ("timeout", String(format: "%.0fs", timeout)),
            ],
            baseDirectory: baseDirectory
        )

        // Step 1: 无锁快路检查
        let initialRecord = SharedCache.readRecord(for: provider, baseDirectory: baseDirectory)
        switch SharedCache.evaluate(initialRecord, maxAge: maxAge, now: requestStart) {
        case let .fresh(age, suppressedID):
            if let usage = initialRecord?.toProviderUsage() {
                var fields: [(String, String)] = [
                    ("mode", "fast_path"),
                    ("age", String(format: "%.1fs", age)),
                    ("fetchedBy", initialRecord?.fetchedBy ?? "unknown"),
                    ("windows", UsageLogger.windowsSummary(usage.windows)),
                ]
                if let suppressedID {
                    fields.append(("note", "window_reset_suppressed:\(suppressedID)"))
                }
                UsageLogger.log(provider, event: "CACHE_HIT", fields: fields, baseDirectory: baseDirectory)
                return usage
            }
        case let .stale(reason):
            UsageLogger.log(
                provider,
                event: "CACHE_MISS",
                fields: [("reason", reason)],
                baseDirectory: baseDirectory
            )
        }

        // Step 2: 同进程先通过 InFlight.coalesce 合并并发请求，保证同进程对同一 provider 只 open 一把锁
        return try await InFlight.shared.coalesce(provider) {
            guard let fileLock = await SharedCache.acquireLock(
                for: provider,
                timeout: timeout,
                baseDirectory: baseDirectory
            ) else {
                // 等锁超时：绝不额外再起 CLI（防止持锁进程卡住时多进程雪崩），若有旧缓存则返回旧缓存
                if let fallback = SharedCache.readRecord(for: provider, baseDirectory: baseDirectory)?.toProviderUsage() {
                    UsageLogger.log(
                        provider,
                        event: "CACHE_FALLBACK_ON_LOCK_TIMEOUT",
                        fields: [("windows", UsageLogger.windowsSummary(fallback.windows))],
                        baseDirectory: baseDirectory
                    )
                    return fallback
                }
                throw AIUsageError(provider: provider, message: "lock acquisition timed out", kind: .timeout)
            }

            // Step 3: 拿到锁后的 Double-Check
            let afterLockNow = Date()
            if let record = SharedCache.readRecord(for: provider, baseDirectory: baseDirectory) {
                // 3a. 无论 maxAge 是否为 0，只要 storedAt >= requestStart - 1s，说明等锁期间（或抢锁前一瞬）刚被别的进程刷新写盘了！
                if let storedAt = record.storedAt,
                   storedAt >= requestStart.addingTimeInterval(-1.0),
                   let usage = record.toProviderUsage()
                {
                    let age = max(0, afterLockNow.timeIntervalSince(storedAt))
                    UsageLogger.log(
                        provider,
                        event: "CACHE_HIT_AFTER_WAIT",
                        fields: [
                            ("reason", "peer_just_updated"),
                            ("age", String(format: "%.2fs", age)),
                            ("fetchedBy", record.fetchedBy ?? "unknown"),
                            ("windows", UsageLogger.windowsSummary(usage.windows)),
                        ],
                        baseDirectory: baseDirectory
                    )
                    fileLock.unlock(baseDirectory: baseDirectory)
                    return usage
                }

                // 3b. 常规新鲜度复核
                if case let .fresh(age, suppressedID) = SharedCache.evaluate(record, maxAge: maxAge, now: afterLockNow),
                   let usage = record.toProviderUsage()
                {
                    var fields: [(String, String)] = [
                        ("reason", "fresh_on_recheck"),
                        ("age", String(format: "%.1fs", age)),
                        ("fetchedBy", record.fetchedBy ?? "unknown"),
                        ("windows", UsageLogger.windowsSummary(usage.windows)),
                    ]
                    if let suppressedID {
                        fields.append(("note", "window_reset_suppressed:\(suppressedID)"))
                    }
                    UsageLogger.log(provider, event: "CACHE_HIT_AFTER_WAIT", fields: fields, baseDirectory: baseDirectory)
                    fileLock.unlock(baseDirectory: baseDirectory)
                    return usage
                }

                // 3c. 失败退避保护（非强制刷新时，如果前一个进程刚刚试过且失败了，在 retryAfter 之前不再连续冲击 CLI）
                if maxAge > 0,
                   let retryAfter = record.retryAfter,
                   afterLockNow < retryAfter
                {
                    let remaining = retryAfter.timeIntervalSince(afterLockNow)
                    UsageLogger.log(
                        provider,
                        event: "BACKOFF_SKIP",
                        fields: [
                            ("remaining", String(format: "%.1fs", remaining)),
                            ("lastErrorKind", record.lastErrorKind ?? "failed"),
                        ],
                        baseDirectory: baseDirectory
                    )
                    fileLock.unlock(baseDirectory: baseDirectory)
                    throw AIUsageError(
                        provider: provider,
                        message: "backed off after recent failure (retry in \(Int(ceil(remaining)))s)",
                        kind: .failed
                    )
                }
            }

            // Step 4: 真正执行取数（期间禁用 App Nap，防止持锁睡死）
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "AIUsageKit CLI fetch (\(provider.rawValue))"
            )
            let cliStart = Date()
            let fetchResult: Result<ProviderUsage, Error>
            do {
                let usage = try await liveFetcher()
                fetchResult = .success(usage)
            } catch {
                fetchResult = .failure(error)
            }
            ProcessInfo.processInfo.endActivity(activity)
            let durationMs = Int(Date().timeIntervalSince(cliStart) * 1000)

            // Step 5: 写盘 -> 释放锁 -> 释放锁之后再发跨进程通知
            switch fetchResult {
            case let .success(usage):
                SharedCache.writeSuccess(usage, now: Date(), baseDirectory: baseDirectory)
                UsageLogger.log(
                    provider,
                    event: "CLI_SUCCESS",
                    fields: [
                        ("source", usage.source),
                        ("durationMs", "\(durationMs)"),
                        ("windows", UsageLogger.windowsSummary(usage.windows)),
                    ],
                    baseDirectory: baseDirectory
                )
                UsageLogger.log(
                    provider,
                    event: "CACHE_WRITE",
                    fields: [("file", "\(provider.rawValue).json")],
                    baseDirectory: baseDirectory
                )
                fileLock.unlock(baseDirectory: baseDirectory)
                SharedCache.postUpdateNotification(for: provider, baseDirectory: baseDirectory)
                return usage

            case let .failure(error):
                let kind = (error as? AIUsageError)?.kind ?? .failed
                SharedCache.writeFailure(
                    provider: provider,
                    errorKind: kind,
                    now: Date(),
                    baseDirectory: baseDirectory
                )
                // 注意：日志绝不打印 error.localizedDescription，防止泄露本地路径或凭据提示
                UsageLogger.log(
                    provider,
                    event: "CLI_FAILURE",
                    fields: [
                        ("kind", kind.rawValue),
                        ("durationMs", "\(durationMs)"),
                        ("backoffSec", "\(Int(SharedCache.failureBackoffSeconds))"),
                    ],
                    baseDirectory: baseDirectory
                )
                fileLock.unlock(baseDirectory: baseDirectory)
                throw error
            }
        }
    }

    private static func fetchLiveWithRetry(
        _ provider: AIProvider,
        timeout: TimeInterval,
        baseDirectory: URL?
    ) async throws -> ProviderUsage {
        // Antigravity 便宜快路：如果 /tmp/agy_statusline_input.json 在 120s 内有完整 5 桶配额，直接采用，免去 7.8s CLI
        if provider == .antigravity,
           let fast = SharedCache.readFreshAntigravityStatusLine(maxAge: 120)
        {
            UsageLogger.log(
                provider,
                event: "STATUSLINE_FASTPATH",
                fields: [("windows", UsageLogger.windowsSummary(fast.windows))],
                baseDirectory: baseDirectory
            )
            return fast
        }

        ChildReaper.reap(olderThan: 10 * 60)
        do {
            return try await self.fetchOnce(provider, timeout: timeout)
        } catch let error as AIUsageError where error.isTimeout || error.isBusy {
            throw error
        } catch {
            // CodexBar 里 Grok 的 billing 请求写死 3 秒超时，几家同时取、或网络慢时偶尔会超时，重试一次基本都能过。
            UsageLogger.log(
                provider,
                event: "CLI_RETRY",
                fields: [("delaySec", "1")],
                baseDirectory: baseDirectory
            )
            try await Task.sleep(for: .seconds(1))
            return try await self.fetchOnce(provider, timeout: timeout)
        }
    }

    private static func fetchOnce(_ provider: AIProvider, timeout: TimeInterval) async throws -> ProviderUsage {
        guard await InFlight.shared.begin(provider) else {
            throw AIUsageError(provider: provider, message: "previous fetch is still running", kind: .busy)
        }
        let startedAt = Date()
        let race = Race<ProviderUsage>()

        // 真正取数的任务。它可能卡住；只有它真正结束时才释放「正在跑」的标记。
        Task.detached {
            do {
                race.finish(.success(try await self.fetchUnbounded(provider)))
            } catch {
                race.finish(.failure(error))
            }
            await InFlight.shared.end(provider)
        }
        // 计时器。到点先返回超时，再清理这次启动的子进程，让卡住的那次也能尽快结束。
        let timer = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            let timeoutError = AIUsageError(
                provider: provider, message: "timed out after \(Int(timeout))s", kind: .timeout)
            if race.finish(.failure(timeoutError)) {
                ChildReaper.reap(names: [ChildReaper.executableName(for: provider)], startedAfter: startedAt)
            }
        }
        defer { timer.cancel() }
        return try await race.value()
    }

    // MARK: - 底层 CodexBarCore 取数

    private struct Route {
        let id: UsageProvider
        let sourceMode: ProviderSourceMode
    }

    /// 每家固定走的路径。都是调各家自己的命令行，凭据和 token 刷新都交给它们：
    /// - Claude：后台起 `claude`，发 `/usage` 读结果。不读钥匙串、不弹窗。
    /// - Antigravity：调 `agy`（`agy -p /usage` 或复用已运行的 agy 本地服务）。
    /// - Grok：起 `grok agent stdio`，调 `_x.ai/billing`。
    private static func route(for provider: AIProvider) -> Route {
        switch provider {
        case .claude: Route(id: .claude, sourceMode: .cli)
        case .antigravity: Route(id: .antigravity, sourceMode: .cli)
        case .grok: Route(id: .grok, sourceMode: .cli)
        }
    }

    private static func fetchUnbounded(_ provider: AIProvider) async throws -> ProviderUsage {
        let route = self.route(for: provider)
        let browser = BrowserDetection()
        let env = self.environment()
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: route.sourceMode,
            includeCredits: false,
            webTimeout: 20,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(),
            // Claude 的取数器自己也带一份环境变量（起 `claude` 子进程用），要和上面保持一致。
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser, environment: env, runtime: .cli),
            browserDetection: browser)

        // background：任何可能弹窗（钥匙串等）的路径都会被跳过，而不是打断用户。
        let outcome = await ProviderInteractionContext.$current.withValue(.background) {
            await ProviderDescriptorRegistry.descriptor(for: route.id).fetchOutcome(context: context)
        }

        switch outcome.result {
        case let .success(result):
            let usage = result.usage
            return ProviderUsage(
                provider: provider,
                plan: usage.loginMethod(for: route.id),
                accountEmail: usage.accountEmail(for: route.id),
                windows: UsageMapping.windows(for: provider, snapshot: usage),
                fetchedAt: usage.updatedAt,
                source: result.strategyID)
        case let .failure(error):
            throw AIUsageError(provider: provider, message: error.localizedDescription)
        }
    }

    /// 从 Finder / launchd 启动的 App 拿到的 PATH 很短，找不到 `claude`、`grok`、`agy`。
    /// 这里把常见安装位置补进去；同时去掉允许导入浏览器 Cookie 的开关，确保那条路一直关着。
    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [
            "\(home)/.local/bin", "\(home)/.grok/bin", "\(home)/.claude/local",
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
        let current = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        return env
    }
}
