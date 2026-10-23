import CodexBarCore
import Foundation

/// 取各家 AI 订阅的真实用量。底层是 CodexBarCore，这里只做三件事：
/// 1. 每家走哪条取数路径写死（见 `route(for:)`），不碰浏览器 Cookie、不读 Claude Code 的钥匙串；
/// 2. 把 CodexBar 的数据整理成统一的 `UsageWindow` 列表；
/// 3. 屏蔽 CodexBarCore 的接口变化 —— 它升级改了签名，只改这个文件。
public enum AIUsage {
    /// 取一家的用量。失败会自动再试一次。
    /// - Parameter timeout: 单次超时秒数。Claude 要在后台起一次 `claude` 读 `/usage`，正常 10 秒左右。
    public static func fetch(_ provider: AIProvider, timeout: TimeInterval = 60) async throws -> ProviderUsage {
        do {
            return try await self.fetchOnce(provider, timeout: timeout)
        } catch {
            // CodexBar 里 Grok 的 billing 请求写死 3 秒超时，几家同时取、或网络慢时偶尔会超时，重试一次基本都能过。
            try await Task.sleep(for: .seconds(1))
            return try await self.fetchOnce(provider, timeout: timeout)
        }
    }

    private static func fetchOnce(_ provider: AIProvider, timeout: TimeInterval) async throws -> ProviderUsage {
        try await withThrowingTaskGroup(of: ProviderUsage.self) { group in
            group.addTask { try await self.fetchUnbounded(provider) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AIUsageError(provider: provider, message: "timed out after \(Int(timeout))s")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw AIUsageError(provider: provider, message: "no result")
            }
            return first
        }
    }

    /// 并发取多家。单家失败不影响其他家。
    public static func fetchAll(
        _ providers: [AIProvider] = AIProvider.allCases,
        timeout: TimeInterval = 60) async -> [AIProvider: Result<ProviderUsage, AIUsageError>]
    {
        await withTaskGroup(of: (AIProvider, Result<ProviderUsage, AIUsageError>).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return (provider, .success(try await self.fetch(provider, timeout: timeout)))
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

    // MARK: - 取数

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
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: route.sourceMode,
            includeCredits: false,
            webTimeout: 20,
            webDebugDumpHTML: false,
            verbose: false,
            env: self.environment(),
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser),
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
