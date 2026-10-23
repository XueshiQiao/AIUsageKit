# AIUsageKit

[English](README.md) | 中文

取各家 AI 编程工具**订阅真实用量**的 Swift 小包：每个额度窗口返回**已用百分比**、**重置时间**、**窗口时间已过百分比**，一眼看出是不是用得比时间快。

| 厂商 | 窗口 |
|---|---|
| **Claude**（Claude Code Pro / Max） | 5 小时、每周；套餐有单模型每周额度时也会带上 |
| **Antigravity**（谷歌） | Gemini 组 5 小时 / 每周，Claude & GPT（第三方）组 5 小时 / 每周；有单独分组（如 Argon）也会带上 |
| **Grok**（SuperGrok） | 每周 |

底层是 Peter Steinberger 的 [CodexBar](https://github.com/steipete/CodexBar) 里的 `CodexBarCore` 库（MIT，只用库，不装 App）。跟各家打交道的脏活都是 CodexBar 干的，这一层只做三件事：

1. **写死每家的取数路径**：都是调各家自己的官方命令行（`claude`、`agy`、`grok`）。不读浏览器 Cookie，不读 Claude Code 的钥匙串，不弹窗。token 过期由各家命令行自己刷新。
2. **跨进程共享缓存与单飞互斥**：缓存与 `flock` 文件锁按厂商拆分在 `~/Library/Caches/AIUsageKit/v1/<provider>.json`（自动剔除 `accountEmail`），本机多个 App 同时运行时，同一家同一时间只有一个进程起 CLI，刷完通过 `DistributedNotificationCenter` 广播给其他 App。详细调试日志记在 `~/Library/Caches/AIUsageKit/logs/usage.log`。
3. **统一数据格式**：整理成同一种 `UsageWindow`。
4. **挡住上游接口变化**：`CodexBarCore` 几乎每天发版、接口不承诺稳定。版本固定在这里，用它的 App 不用操心。

> 个人项目，原样分享。我在 macOS 26 上配合下面这些命令行在用；各家接口变化时不保证及时跟进。

## 前提

- macOS 14+，Swift 6.2+（Xcode 26+）。
- 要读哪家，就得在这台机器上**装好并登录**哪家的命令行：

  | 厂商 | 命令行 | 大约耗时 |
  |---|---|---|
  | `claude` | [Claude Code](https://docs.claude.com/en/docs/claude-code)：后台在伪终端里起 `claude`，发 `/usage` 读结果 | ~10 秒 |
  | `antigravity` | [Antigravity CLI](https://antigravity.google) `agy` | ~7 秒 |
  | `grok` | [Grok Build](https://github.com/xai-org/grok-build) `grok`：通过 `grok agent stdio` 调 `_x.ai/billing` | ~3 秒 |

  哪家的命令行没装、没登录，那一家返回错误，不影响其他家。不需要另外授权。
- **App 不能开 App Sandbox**：要启动这些命令行。Hardened Runtime 没问题。
- 主程序会多大约 **40MB**（`CodexBarCore` 里有一百多家的代码和一个 JS 引擎）。

> 个人 / AI Pro / Ultra 账号的 Gemini 额度只能从 `antigravity` 拿：谷歌 2026-06-18 起不再对这类账号开放 Gemini CLI 的配额接口。

## 安装

**只能按 `branch:` / `revision:` / `path:` 依赖，不能按版本号**（`from:` / `exact:` 会解析失败）。原因：CodexBar 自己按 commit 依赖了一个包，SwiftPM 不允许按版本号依赖这种包，这个限制会一路传下来。

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/XueshiQiao/AIUsageKit.git", branch: "main"),
    // 或固定 commit：revision: "<sha>"
    // 或本地 checkout：.package(path: "../AIUsageKit")
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [.product(name: "AIUsageKit", package: "AIUsageKit")]),
]
```

Xcode：File → Add Package Dependencies…，填地址，规则选 `main` 分支。

### 打包时带上资源包（自己拼 .app 的必看）

`CodexBarCore` 带资源文件，SwiftPM 编译后会在产物目录多出几个 `.bundle`（`CodexBar_CodexBarCore.bundle`、`SweetCookieKit_SweetCookieKit.bundle`、`swift-crypto_Crypto.bundle`）。

- **用 Xcode 工程编译**：自动拷进 App，不用管。
- **用 `swift build` + 脚本拼 `.app`**：必须拷进 `Contents/Resources`。**漏了编译不报错，运行时一读资源就崩。**

```bash
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)
cp "$BIN/MyApp" "$APP/Contents/MacOS/MyApp"
mkdir -p "$APP/Contents/Resources"
for b in "$BIN"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
# 然后照常 codesign（拷完 bundle 再签）
```

## 用法

```swift
import AIUsageKit

// 取一家。失败会自动重试一次，单次默认 60 秒超时。
let usage = try await AIUsage.fetch(.claude)
print(usage.plan ?? "-")                 // "Max"
for w in usage.windows {
    print(w.title,                        // "5-hour"
          w.usedPercent ?? -1,            // 已用 %
          w.elapsedPercent() ?? -1,       // 窗口时间已过 %
          w.resetsAt as Any)              // 重置时间
}

// 并发取多家，单家失败不影响别家。三家一起大约 10 秒。
let results = await AIUsage.fetchAll([.claude, .antigravity, .grok])
switch results[.grok] {
case let .success(usage): print(usage.windows)
case let .failure(error): print(error.message)
case nil: break
}

// 按 id 取某个窗口
let weekly = usage.window(id: "claude.weekly")
```

### 在 SwiftUI App 里用

- **取数**放后台定时做，5 分钟一次足够（每次要起几个子进程，别太频繁）。
- **「时间已过」不要靠重新取数来更新**：`elapsedPercent(at:)` 按传入时间现算，UI 每 30 秒左右重算一次即可。
- 某个窗口过了 `resetsAt`，数据就是重置前的了：按 0% 显示，并提前触发一次刷新（`isPastReset(at:)`）。
- 某家失败时保留上一次的数据，只标注错误。

```swift
import AIUsageKit
import SwiftUI

@MainActor
final class UsageModel: ObservableObject {
    @Published var usages: [AIProvider: ProviderUsage] = [:]
    @Published var errors: [AIProvider: String] = [:]
    @Published var now = Date()
    private var timer: Timer?
    private var lastFetch: Date?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                let due = self.lastFetch.map { self.now.timeIntervalSince($0) > 300 } ?? true
                let justReset = self.usages.values.contains { $0.windows.contains { $0.isPastReset(at: self.now) } }
                if due || justReset { self.refresh() }
            }
        }
    }

    func refresh() {
        lastFetch = Date()
        Task {
            let results = await AIUsage.fetchAll([.claude, .antigravity, .grok])
            for (provider, result) in results {
                switch result {
                case let .success(usage): usages[provider] = usage; errors[provider] = nil
                case let .failure(error): errors[provider] = error.message   // 保留旧数据
                }
            }
        }
    }
}

struct UsageRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let used = window.isPastReset(at: now) ? 0 : window.usedPercent
        HStack {
            Text(window.title)
            Spacer()
            Text(used.map { "\(Int($0))%" } ?? "–")                       // nil = 用量未知，别显示成 0%
            Text(window.elapsedPercent(at: now).map { "时间已过 \(Int($0))%" } ?? "")
        }
    }
}
```

## 数据结构

`ProviderUsage`：

| 字段 | 说明 |
|---|---|
| `provider` | `.claude` / `.antigravity` / `.grok` |
| `plan` | 订阅档位，如 `Max`、`SuperGrok`；Antigravity 拿不到，为 nil |
| `accountEmail` | 账号邮箱，可能为 nil（只在内存里，这个包不会写到任何地方） |
| `windows` | `[UsageWindow]`，顺序固定：5 小时在前，每周在后；Antigravity 先 Gemini 组 |
| `fetchedAt` | 数据时间 |
| `source` | CodexBar 实际用的取数策略，排查用，如 `claude.cli` |

`UsageWindow`：

| 字段 | 说明 |
|---|---|
| `id` | 稳定标识，见下表。可以拿来存「显示哪几个窗口」之类的设置 |
| `title` / `group` | 英文显示名（界面上建议按 `kind` + `group` 自己拼中文名） / 分组名（`Gemini`、`Claude/GPT`；Claude 单模型额度是模型名；其余为 nil） |
| `kind` | `.session`（5 小时）/ `.weekly` / `.other` |
| `usedPercent` | 已用 0–100。**为 nil 表示厂商没给出用量**，不要当 0 显示 |
| `resetsAt` | 下次重置时间 |
| `windowSeconds` | 窗口长度（5 小时 = 18000，每周 = 604800） |
| `elapsedPercent(at:)` | (now − (resetsAt − windowSeconds)) / windowSeconds，夹在 0–100 |
| `isPastReset(at:)` | 是否已过重置时间 |

所有类型都是 `Codable` + `Sendable`。

窗口 id：

| 厂商 | id |
|---|---|
| `claude` | `claude.session`、`claude.weekly`；单模型额度为 `claude.weekly.<模型>`（如 `claude.weekly.fable`）或 `claude.weekly.model`（Sonnet/Opus） |
| `antigravity` | `antigravity.gemini-5h`、`antigravity.gemini-weekly`、`antigravity.3p-5h`、`antigravity.3p-weekly`；额外分组保留自己的 id 和 `group` 名 |
| `grok` | `grok.weekly` |

## 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 解析依赖报 `depends on an unstable-version package 'vortex'` | 用了 `from:` / `exact:`。改成 `branch:` / `revision:` / `path:` |
| 运行时一取数就崩，跟 `Bundle.module` 有关 | 资源包没拷进 `Contents/Resources`，见「打包时带上资源包」 |
| 某家一直报未登录 / 过期 | 在终端里跑一次对应命令行（`claude` / `agy` / `grok`）重新登录 |
| 从 Finder / launchd 启动后某家报找不到命令 | GUI App 的 PATH 很短。已自动补上 `~/.local/bin`、`~/.grok/bin`、`~/.claude/local`、`/opt/homebrew/bin`、`/usr/local/bin`；装在别处的话改 `AIUsage.swift` 里的 `environment()` |
| Grok 偶尔超时 | CodexBar 里 Grok 的 billing 请求写死 3 秒超时，并发或网络慢时会超。已经自动重试一次 |
| 第一次 `swift build` 卡在拉 CodexBar 很久 | CodexBar 历史很大。网络慢时先浅克隆对应 tag，再 `swift package config set-mirror --original https://github.com/steipete/CodexBar.git --mirror <本地路径>`（只写进被 gitignore 的 `.swiftpm/`） |

## 调试命令行

```bash
swift run aiusage                  # 三家都取，表格
swift run aiusage claude grok      # 只取指定的
swift run aiusage --json           # JSON，含 elapsedPercent
swift test                         # 单元测试
```

## 加新厂商

`CodexBarCore` 已经支持一百多家（DeepSeek、MiniMax 等）。加一家要改：

1. `Models.swift` 的 `AIProvider` 加一个 case；
2. `AIUsage.swift` 的 `route(for:)` 写它走哪条路径（只选不碰 Cookie 的：`.cli`、`.oauth`、`.api`）；API key 从环境变量给（CodexBar 认 `DEEPSEEK_API_KEY`、`MINIMAX_CODING_API_KEY` 这类）；
3. `UsageMapping.swift` 按它的数据形状整理窗口；
4. 跑一次 `swift run aiusage <名字>` 看实际返回，补一条单元测试。

## 升级 CodexBarCore

改 `Package.swift` 里的 `revision:`（目标 tag 对应的 commit）→ `swift build` → `swift test` → `swift run aiusage` 三家都看一遍。上游接口确实会变：`main` 上有的 `AntigravityStatusProbe.isQuotaSummaryWindowID`，两天前的 v0.79.0 里就还没有。所以这一层尽量只用最基础的几个类型（`ProviderFetchContext`、`ProviderDescriptorRegistry`、`UsageSnapshot`、`RateWindow`、`NamedRateWindow`）。

当前固定的上游版本：CodexBar **v0.79.0**（commit `b49d42eb`）。

## 其他

- CodexBarCore 可能会往钥匙串 / UserDefaults 写几条 `com.steipete.codexbar.*` 的缓存。
- 与 Anthropic、谷歌、xAI、CodexBar 均无关联。

## 许可证

[MIT](LICENSE)。`CodexBarCore` 由 Peter Steinberger 以 MIT 协议发布。
