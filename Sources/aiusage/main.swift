import AIUsageKit
import Foundation

// 用法：
//   aiusage                      # 三家都取，表格输出
//   aiusage claude grok          # 只取指定的
//   aiusage --json antigravity   # JSON 输出（含 elapsedPercent）

var args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
args.removeAll { $0 == "--json" }

var providers: [AIProvider] = []
for arg in args {
    guard let provider = AIProvider(rawValue: arg) else {
        FileHandle.standardError.write(Data("unknown provider: \(arg). choose from: \(AIProvider.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8))
        exit(2)
    }
    providers.append(provider)
}
if providers.isEmpty { providers = AIProvider.allCases }

let results = await AIUsage.fetchAll(providers)
let now = Date()

if json {
    struct WindowOut: Encodable {
        let window: UsageWindow
        let elapsedPercent: Double?
        func encode(to encoder: Encoder) throws {
            try self.window.encode(to: encoder)
            var c = encoder.container(keyedBy: Key.self)
            try c.encodeIfPresent(self.elapsedPercent, forKey: .elapsedPercent)
        }
        enum Key: String, CodingKey { case elapsedPercent }
    }
    struct ProviderOut: Encodable {
        let provider: String
        let plan: String?
        let source: String?
        let fetchedAt: Date?
        let windows: [WindowOut]
        let error: String?
    }
    let out = providers.map { provider -> ProviderOut in
        switch results[provider] {
        case let .success(usage):
            ProviderOut(
                provider: provider.rawValue, plan: usage.plan, source: usage.source, fetchedAt: usage.fetchedAt,
                windows: usage.windows.map { WindowOut(window: $0, elapsedPercent: $0.elapsedPercent(at: now)) },
                error: nil)
        case let .failure(error):
            ProviderOut(provider: provider.rawValue, plan: nil, source: nil, fetchedAt: nil, windows: [], error: error.message)
        case nil:
            ProviderOut(provider: provider.rawValue, plan: nil, source: nil, fetchedAt: nil, windows: [], error: "no result")
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(out))
    print()
    exit(0)
}

func pct(_ value: Double?) -> String {
    guard let value else { return "  -  " }
    return String(format: "%4.0f%%", value)
}

let resetFormatter = DateFormatter()
resetFormatter.dateFormat = "MM-dd HH:mm"

for provider in providers {
    switch results[provider] {
    case let .success(usage):
        print("\(provider.displayName)  [\(usage.plan ?? "?")]  via \(usage.source)")
        for w in usage.windows {
            let title = w.title.padding(toLength: 22, withPad: " ", startingAt: 0)
            let reset = w.resetsAt.map { resetFormatter.string(from: $0) } ?? "-"
            print("  \(title) 已用 \(pct(w.usedPercent))   时间已过 \(pct(w.elapsedPercent(at: now)))   重置 \(reset)   id=\(w.id)")
        }
    case let .failure(error):
        print("\(provider.displayName)  失败：\(error.message)")
    case nil:
        print("\(provider.displayName)  无结果")
    }
}
