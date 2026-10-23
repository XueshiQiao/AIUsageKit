import CodexBarCore
import Foundation

/// 把 CodexBar 的 `UsageSnapshot` 整理成 `[UsageWindow]`。
///
/// CodexBar 的数据长这样：
/// - `primary` / `secondary` / `tertiary` 三个固定槽位，各家含义不同；
/// - `extraRateWindows` 放其余的命名窗口：Antigravity 的全部分组额度、Claude 的单模型每周额度（如 Fable）等。
enum UsageMapping {
    static func windows(for provider: AIProvider, snapshot: UsageSnapshot) -> [UsageWindow] {
        var result: [UsageWindow] = []
        var seen: Set<String> = []
        func append(_ window: UsageWindow) {
            guard seen.insert(window.id).inserted else { return }
            result.append(window)
        }

        let extras = (snapshot.extraRateWindows ?? []).filter { !$0.window.isSyntheticPlaceholder }

        switch provider {
        case .antigravity:
            // Antigravity 的 primary/secondary 只是从各分组里挑出来的代表，完整数据都在 extras 里。
            // 前缀自己判断，不调 CodexBar 的 helper —— 那个函数 v0.79.0 里还没有，靠不住。
            let prefix = "antigravity-quota-summary-"
            let summary = extras.filter { $0.id.hasPrefix(prefix) }
            if summary.isEmpty {
                self.appendSlots(provider: provider, snapshot: snapshot, append: append)
            } else {
                for named in summary {
                    append(self.window(
                        provider: provider,
                        named: named,
                        idSuffix: String(named.id.dropFirst(prefix.count))))
                }
            }

        case .claude, .grok:
            self.appendSlots(provider: provider, snapshot: snapshot, append: append)
            for named in extras {
                append(self.window(provider: provider, named: named, idSuffix: self.claudeStyleSuffix(named.id)))
            }
        }
        return result
    }

    // MARK: - primary / secondary / tertiary

    private static func appendSlots(
        provider: AIProvider, snapshot: UsageSnapshot, append: (UsageWindow) -> Void)
    {
        let slots: [(String, RateWindow?)] = [
            ("primary", snapshot.primary), ("secondary", snapshot.secondary), ("tertiary", snapshot.tertiary),
        ]
        for (slot, window) in slots {
            guard let window, !window.isSyntheticPlaceholder else { continue }
            let kind = self.kind(windowMinutes: window.windowMinutes)
            let (idSuffix, title): (String, String) = switch (slot, kind) {
            case ("tertiary", _):
                // Claude 的 tertiary 是 Sonnet / Opus 这类单模型每周额度。
                ("weekly.model", self.tertiaryTitle(provider))
            case (_, .session): ("session", "5-hour")
            case (_, .weekly): ("weekly", "Weekly")
            case (_, .other): (slot, slot.capitalized)
            }
            append(UsageWindow(
                id: "\(provider.rawValue).\(idSuffix)",
                title: title,
                group: nil,
                kind: kind,
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt,
                windowSeconds: window.windowMinutes.map { TimeInterval($0) * 60 }))
        }
    }

    private static func tertiaryTitle(_ provider: AIProvider) -> String {
        let id: UsageProvider = switch provider {
        case .claude: .claude
        case .antigravity: .antigravity
        case .grok: .grok
        }
        return ProviderDescriptorRegistry.descriptor(for: id).metadata.opusLabel ?? "Model weekly"
    }

    // MARK: - extraRateWindows

    private static func window(provider: AIProvider, named: NamedRateWindow, idSuffix: String) -> UsageWindow {
        let kind = self.kind(windowMinutes: named.window.windowMinutes)
        return UsageWindow(
            id: "\(provider.rawValue).\(idSuffix)",
            title: named.title,
            group: self.group(provider: provider, title: named.title, kind: kind),
            kind: kind,
            usedPercent: named.usageKnown ? named.window.usedPercent : nil,
            resetsAt: named.window.resetsAt,
            windowSeconds: named.window.windowMinutes.map { TimeInterval($0) * 60 })
    }

    /// `claude-weekly-scoped-fable` → `weekly.fable`；其它 `claude-xxx` → `xxx`。
    private static func claudeStyleSuffix(_ id: String) -> String {
        let scoped = "claude-weekly-scoped-"
        if id.hasPrefix(scoped) { return "weekly." + id.dropFirst(scoped.count) }
        if id.hasPrefix("claude-") { return String(id.dropFirst("claude-".count)) }
        if id.hasPrefix("grok-") { return String(id.dropFirst("grok-".count)) }
        return id
    }

    /// Antigravity 的标题是「分组名 + 窗口名」，例如 `Gemini 5-hour`、`Gemini 4 Argon weekly`，去掉尾巴就是分组。
    /// Claude 单模型额度标题是 `Fable only`，分组取模型名。
    private static func group(provider: AIProvider, title: String, kind: UsageWindow.Kind) -> String? {
        switch provider {
        case .antigravity:
            for suffix in [" 5-hour", " weekly"] where title.hasSuffix(suffix) {
                return String(title.dropLast(suffix.count))
            }
            return title
        case .claude:
            if title.hasSuffix(" only") { return String(title.dropLast(" only".count)) }
            return nil
        case .grok:
            return nil
        }
    }

    static func kind(windowMinutes: Int?) -> UsageWindow.Kind {
        switch windowMinutes {
        case 300: .session
        case 10080: .weekly
        default: .other
        }
    }
}
