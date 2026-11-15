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
        guard let record = SharedCache.readRecord(for: provider) else { return nil }
        if provider == .antigravity, record.source == "antigravity.offline" || record.windows.isEmpty {
            return nil
        }
        return record.toProviderUsage()
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
        statusLineURL: URL? = nil,
        antigravityActivityURLs: [URL]? = nil,
        liveFetcher: @Sendable @escaping () async throws -> ProviderUsage
    ) async throws -> ProviderUsage {
        let resolvedStatusLineURL = statusLineURL
            ?? (baseDirectory == nil ? SharedCache.defaultAntigravityStatusLineURL : nil)
        let resolvedActivityURLs = antigravityActivityURLs
            ?? (baseDirectory == nil ? SharedCache.defaultAntigravityActivityURLs : [])
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
                if let fallbackRecord = SharedCache.readRecord(for: provider, baseDirectory: baseDirectory),
                   !(provider == .antigravity && (fallbackRecord.source == "antigravity.offline" || fallbackRecord.windows.isEmpty)),
                   let fallback = fallbackRecord.toProviderUsage()
                {
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

            // Step 3: 拿到锁后的 Double-Check 与多级快路门控
            let afterLockNow = Date()
            let record = SharedCache.readRecord(for: provider, baseDirectory: baseDirectory)
            if let record {
                // 3a. 无论 maxAge 是否为 0，只要 storedAt >= requestStart - 1s，说明等锁期间（或抢锁前一瞬）刚被别的进程刷新写盘了！
                let validForPeerReuse = !(provider == .antigravity && (record.source == "antigravity.offline" || record.windows.isEmpty))
                if validForPeerReuse,
                   let storedAt = record.storedAt,
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
            }

            // 3c. Antigravity 第 1 层快路：本地状态行快照（/tmp/agy_statusline_input.json）
            // 状态行在 max(maxAge, 300) 秒内、或比缓存 storedAt 更新，且所有桶均未过重置时间时，0ms 直接采纳并落盘广播。
            var statuslineMissReason = "not_checked"
            if provider == .antigravity {
                if let statusLineURL = resolvedStatusLineURL {
                    let slEvalStart = Date()
                    switch SharedCache.evaluateAntigravityStatusLine(
                        maxAge: maxAge,
                        cachedStoredAt: record?.storedAt,
                        fileURL: statusLineURL,
                        now: afterLockNow
                    ) {
                    case let .hit(fast, trigger, fileAge):
                        let elapsedMs = Int(Date().timeIntervalSince(slEvalStart) * 1000)
                        SharedCache.writeSuccess(fast, now: afterLockNow, baseDirectory: baseDirectory)
                        let planTag = fast.plan.map { "\"\($0)\"" } ?? "none"
                        UsageLogger.log(
                            provider,
                            event: "STATUSLINE_HIT",
                            fields: [
                                ("trigger", trigger),
                                ("fileAge", String(format: "%.1fs", fileAge)),
                                ("plan", planTag),
                                ("elapsedMs", "\(elapsedMs)"),
                                ("windows", UsageLogger.windowsSummary(fast.windows)),
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
                        return fast
                    case let .miss(reason):
                        statuslineMissReason = reason
                    }
                } else {
                    statuslineMissReason = "disabled"
                }
            }

            // 3d. 失败退避保护（非强制刷新时，如果前一个进程刚刚试过且失败了，在 retryAfter 之前不再连续冲击 CLI）
            if maxAge > 0,
               let record,
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

            // 3e. Antigravity 第 2 层门控：全局会话汇总库闲置「零启动」复用
            // 满足闲置条件时直接 0ms 返回缓存快照（不覆盖 storedAt，以便 60m 兜底计时正常推进）。
            if provider == .antigravity {
                let idleEvalStart = Date()
                switch SharedCache.evaluateIdleAntigravityCache(
                    record,
                    maxAge: maxAge,
                    activityURLs: resolvedActivityURLs,
                    now: afterLockNow
                ) {
                case let .reuse(idleUsage, cacheAge, summaryDelta, latestFile, nextResetIn):
                    let elapsedMs = Int(Date().timeIntervalSince(idleEvalStart) * 1000)
                    let deltaStr = summaryDelta.map { String(format: "%+.1fs", $0) } ?? "no_files"
                    let fileStr = latestFile ?? "none"
                    let resetStr = nextResetIn.map { String(format: "%.0fs", $0) } ?? "none"
                    UsageLogger.log(
                        provider,
                        event: "IDLE_REUSE",
                        fields: [
                            ("action", "skip_agy"),
                            ("cacheAge", String(format: "%.1fs", cacheAge)),
                            ("summaryDbMtimeDelta", deltaStr),
                            ("summaryFile", fileStr),
                            ("nextResetIn", resetStr),
                            ("elapsedMs", "\(elapsedMs)"),
                            ("windows", UsageLogger.windowsSummary(idleUsage.windows)),
                        ],
                        baseDirectory: baseDirectory
                    )
                    fileLock.unlock(baseDirectory: baseDirectory)
                    return idleUsage
                case let .bypass(liveReason):
                    let stripped = Self.strippedSSHVariableNames()
                    let strippedTag = stripped.isEmpty ? "none" : stripped.joined(separator: ",")
                    let timeoutCap = Int(Self.effectiveLiveTimeout(for: provider, requested: timeout))
                    UsageLogger.log(
                        provider,
                        event: "LIVE_SPAWN_REASON",
                        fields: [
                            ("reason", liveReason),
                            ("statusline", statuslineMissReason),
                            ("sshVarsStripped", strippedTag),
                            ("timeoutCap", "\(timeoutCap)s"),
                        ],
                        baseDirectory: baseDirectory
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
                try Self.validateLiveUsage(
                    usage,
                    preservedCachedCount: record?.windows.count ?? 0,
                    baseDirectory: baseDirectory
                )
                fetchResult = .success(usage)
            } catch {
                fetchResult = .failure(error)
            }
            ProcessInfo.processInfo.endActivity(activity)
            let completedNow = Date()
            let durationMs = Int(completedNow.timeIntervalSince(cliStart) * 1000)

            // Step 5: 写盘（storedAt 取在子进程彻底退出之后） -> 释放锁 -> 释放锁之后再发跨进程通知
            switch fetchResult {
            case let .success(usage):
                SharedCache.writeSuccess(usage, now: completedNow, baseDirectory: baseDirectory)
                UsageLogger.log(
                    provider,
                    event: "CLI_SUCCESS",
                    fields: [
                        ("source", usage.source),
                        ("elapsedMs", "\(durationMs)"),
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
                let backoff = SharedCache.failureBackoffSeconds(for: provider)
                SharedCache.writeFailure(
                    provider: provider,
                    errorKind: kind,
                    now: completedNow,
                    backoff: backoff,
                    baseDirectory: baseDirectory
                )
                // 注意：日志绝不打印 error.localizedDescription，防止泄露本地路径或凭据提示
                UsageLogger.log(
                    provider,
                    event: "CLI_FAILURE",
                    fields: [
                        ("kind", kind.rawValue),
                        ("elapsedMs", "\(durationMs)"),
                        ("durationMs", "\(durationMs)"),
                        ("backoffSec", "\(Int(backoff))"),
                    ],
                    baseDirectory: baseDirectory
                )
                fileLock.unlock(baseDirectory: baseDirectory)
                throw error
            }
        }
    }

    static func effectiveLiveTimeout(for provider: AIProvider, requested timeout: TimeInterval) -> TimeInterval {
        switch provider {
        case .antigravity: min(timeout, 20)
        case .claude, .grok: timeout
        }
    }

    static func runWithProviderRetry(
        _ provider: AIProvider,
        baseDirectory: URL?,
        attempt: @Sendable () async throws -> ProviderUsage
    ) async throws -> ProviderUsage {
        do {
            return try await attempt()
        } catch let error as AIUsageError where error.isTimeout || error.isBusy {
            throw error
        } catch {
            // CodexBar 里 Grok 的 billing 请求写死 3 秒超时，几家同时取、或网络慢时偶尔会超时，重试一次基本都能过；
            // 仅对 Grok 重试，避免 Antigravity / Claude 出错时重复冷启动重量级子进程。
            guard provider == .grok else {
                throw error
            }
            UsageLogger.log(
                provider,
                event: "CLI_RETRY",
                fields: [("delaySec", "1")],
                baseDirectory: baseDirectory
            )
            try await Task.sleep(for: .seconds(1))
            return try await attempt()
        }
    }

    private static func fetchLiveWithRetry(
        _ provider: AIProvider,
        timeout: TimeInterval,
        baseDirectory: URL?
    ) async throws -> ProviderUsage {
        let effectiveTimeout = Self.effectiveLiveTimeout(for: provider, requested: timeout)
        ChildReaper.reap(olderThan: 10 * 60)
        return try await Self.runWithProviderRetry(provider, baseDirectory: baseDirectory) {
            try await self.fetchOnce(provider, timeout: effectiveTimeout)
        }
    }

    private static func fetchOnce(_ provider: AIProvider, timeout: TimeInterval) async throws -> ProviderUsage {
        try await Self.runBounded(
            provider,
            timeout: timeout,
            reapNames: [ChildReaper.executableName(for: provider)]
        ) {
            try await self.fetchUnbounded(provider)
        }
    }

    static func runBounded(
        _ provider: AIProvider,
        timeout: TimeInterval,
        reapNames: Set<String> = [],
        work: @Sendable @escaping () async throws -> ProviderUsage
    ) async throws -> ProviderUsage {
        guard await InFlight.shared.begin(provider) else {
            throw AIUsageError(provider: provider, message: "previous fetch is still running", kind: .busy)
        }
        let startedAt = Date()
        let race = Race<ProviderUsage>()

        // 真正取数的受控任务：保留句柄以便在超时或外部取消时立即传播协作式取消（中止后续 fallback 策略链），
        // 且只有底层真正结束时才释放「正在跑」的标记。
        let worker = Task.detached {
            do {
                race.finish(.success(try await work()))
            } catch {
                race.finish(.failure(error))
            }
            await InFlight.shared.end(provider)
        }
        // 计时器：到点先取消 worker 任务传播取消信号，再清理本次启动的子进程组。
        let timer = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            let timeoutError = AIUsageError(
                provider: provider, message: "timed out after \(Int(timeout))s", kind: .timeout)
            if race.finish(.failure(timeoutError)) {
                worker.cancel()
                if !reapNames.isEmpty {
                    ChildReaper.reap(names: reapNames, startedAfter: startedAt)
                }
            }
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await race.value()
        } onCancel: {
            timer.cancel()
            worker.cancel()
            if race.finish(.failure(CancellationError())), !reapNames.isEmpty {
                ChildReaper.reap(names: reapNames, startedAfter: startedAt)
            }
        }
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
            let mapped = ProviderUsage(
                provider: provider,
                plan: usage.loginMethod(for: route.id),
                accountEmail: usage.accountEmail(for: route.id),
                windows: UsageMapping.windows(for: provider, snapshot: usage),
                fetchedAt: usage.updatedAt,
                source: result.strategyID)
            let existingCachedCount = SharedCache.readRecord(for: provider)?.windows.count ?? 0
            try Self.validateLiveUsage(mapped, preservedCachedCount: existingCachedCount, baseDirectory: nil)
            return mapped
        case let .failure(error):
            throw AIUsageError(provider: provider, message: error.localizedDescription)
        }
    }

    /// 拒绝把不含真实配额的离线会话计数兜底（`antigravity.offline`）或空窗口当成成功快照覆写磁盘缓存，并记录拦截日志。
    static func validateLiveUsage(
        _ usage: ProviderUsage,
        preservedCachedCount: Int = 0,
        baseDirectory: URL? = nil
    ) throws {
        if usage.provider == .antigravity {
            if usage.source == "antigravity.offline" || usage.windows.isEmpty {
                let reason = usage.source == "antigravity.offline" ? "offline_strategy" : "empty_windows"
                UsageLogger.log(
                    .antigravity,
                    event: "OFFLINE_GUARD_REJECTED",
                    fields: [
                        ("strategyID", usage.source),
                        ("reason", reason),
                        ("windowsCount", "\(usage.windows.count)"),
                        ("preservedCachedWindows", "\(preservedCachedCount)"),
                    ],
                    baseDirectory: baseDirectory
                )
                throw AIUsageError(
                    provider: .antigravity,
                    message: usage.source == "antigravity.offline"
                        ? "offline fallback carries no quota data"
                        : "no quota windows returned",
                    kind: .failed
                )
            }
        }
    }

    private static let sshEnvKeys = ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"]

    static func strippedSSHVariableNames(
        from base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        Self.sshEnvKeys.filter { key in
            guard let val = base[key] else { return false }
            return !val.isEmpty
        }
    }

    /// 从 Finder / launchd / tmux 启动的桌面 App 可能缺少常见安装路径或继承了残留的 SSH 环境变量：
    /// - 补全常见 CLI 路径；
    /// - 剥离浏览器 Cookie 导入开关；
    /// - 剥离 `SSH_CONNECTION` / `SSH_CLIENT` / `SSH_TTY`，防止 `agy` 误判为远程 SSH 会话切到文件凭证与本机 Keychain 双轨冲突；
    /// - 注入 `AGY_CLI_DISABLE_AUTO_UPDATE=true`，禁止用量探针触发 `agy` 后台自更新。
    static func environment(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for key in ["CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT"] + Self.sshEnvKeys {
            env.removeValue(forKey: key)
        }
        env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
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
