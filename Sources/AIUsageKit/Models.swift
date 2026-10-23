import Foundation

/// 支持的厂商。每家走哪条取数路径写死在 `AIUsage.swift` 的 `route(for:)` 里。
public enum AIProvider: String, CaseIterable, Codable, Sendable {
    /// Claude Code 订阅（Pro / Max）。
    case claude
    /// Antigravity 的配额：Gemini 组、Claude/GPT（第三方）组，以及 Pro 等档位可能出现的单独分组（如 Argon）。
    /// 个人 / AI Pro / Ultra 账号的 Gemini 额度现在只能从这里拿（Gemini CLI 那条路谷歌 2026-06 已关）。
    case antigravity
    /// SuperGrok 订阅。
    case grok

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        case .grok: "Grok"
        }
    }
}

/// 一个额度窗口：比如「Claude 5 小时」「Gemini 每周」「Fable 每周（单独额度）」。
public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// 5 小时滚动窗口。
        case session
        /// 每周窗口。
        case weekly
        /// 其他长度或未知长度。
        case other
    }

    /// 稳定的标识，可用来存设置、做匹配。例：`claude.session`、`claude.weekly`、`claude.weekly.fable`、
    /// `antigravity.gemini-5h`、`antigravity.3p-weekly`、`grok.weekly`。
    public let id: String
    /// 给人看的名字。例：`5-hour`、`Weekly`、`Fable only`、`Gemini 5-hour`、`Claude/GPT weekly`。
    public let title: String
    /// 分组。Antigravity 是 `Gemini` / `Claude/GPT` / `Gemini 4 Argon` 这类；Claude 的单模型额度是模型名；其余为 nil。
    public let group: String?
    public let kind: Kind
    /// 已用百分比 0–100。厂商没给出用量时为 nil（不要当成 0 或 100 显示）。
    public let usedPercent: Double?
    /// 下次重置时间。
    public let resetsAt: Date?
    /// 窗口长度（秒）。5 小时 = 18000，每周 = 604800。
    public let windowSeconds: TimeInterval?

    public init(
        id: String, title: String, group: String?, kind: Kind,
        usedPercent: Double?, resetsAt: Date?, windowSeconds: TimeInterval?)
    {
        self.id = id
        self.title = title
        self.group = group
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
    }

    /// 当前窗口里时间已经过去的百分比 0–100。
    ///
    /// 窗口起点 = 重置时间 − 窗口长度。比如 5 小时窗口还有 4 小时重置，就是过去了 20%。
    /// 拿它和 `usedPercent` 比，就知道用得快不快：用了 30% 但时间只过了 20%，说明超前了。
    /// 这是按传入时间现算的，UI 定时刷新这个值即可，不用重新请求厂商。
    /// 缺重置时间或窗口长度时返回 nil。
    public func elapsedPercent(at now: Date = Date()) -> Double? {
        guard let resetsAt, let windowSeconds, windowSeconds > 0 else { return nil }
        let start = resetsAt.addingTimeInterval(-windowSeconds)
        let elapsed = now.timeIntervalSince(start) / windowSeconds * 100
        return min(100, max(0, elapsed))
    }

    /// 已经过了重置时间（数据是重置前取的，已经过期）。
    public func isPastReset(at now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return now >= resetsAt
    }
}

/// 一家厂商的一次取数结果。
public struct ProviderUsage: Codable, Equatable, Sendable {
    public let provider: AIProvider
    /// 订阅档位，例如 `Max`、`SuperGrok`。拿不到时为 nil。
    public let plan: String?
    /// 账号邮箱。拿不到时为 nil。
    public let accountEmail: String?
    public let windows: [UsageWindow]
    public let fetchedAt: Date
    /// CodexBar 实际用的取数策略，排查问题用。例：`claude.cli`、`grok.cli`、`antigravity.cli-https`。
    public let source: String

    public init(
        provider: AIProvider, plan: String?, accountEmail: String?,
        windows: [UsageWindow], fetchedAt: Date, source: String)
    {
        self.provider = provider
        self.plan = plan
        self.accountEmail = accountEmail
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.source = source
    }

    public func window(id: String) -> UsageWindow? {
        self.windows.first { $0.id == id }
    }
}

public struct AIUsageError: Error, LocalizedError, Sendable {
    public let provider: AIProvider
    public let message: String

    public var errorDescription: String? {
        "\(self.provider.displayName): \(self.message)"
    }
}
