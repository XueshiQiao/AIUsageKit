# AIUsageKit

取各家 AI 订阅真实用量的 Swift 包：每个额度窗口的**已用百分比**、**重置时间**、**窗口时间已过百分比**。

底层用 [CodexBar](https://github.com/steipete/CodexBar) 的 `CodexBarCore` 库（MIT，只用库，不装 App）。这一层只做三件事：

1. **写死每家的取数路径**：都是调各家自己的命令行，不读浏览器 Cookie，不读 Claude Code 的钥匙串，不弹窗。token 过期由各家命令行自己刷新。
2. **统一数据格式**：各家五花八门的槽位整理成同一种 `UsageWindow` 列表。
3. **挡住上游接口变化**：`CodexBarCore` 几乎每天发版、接口不承诺稳定。版本固定在 `Package.swift`，升级时只改这里。

已接入的项目：[DockSidecar](https://github.com/XueshiQiao/DockSidecar)（`Sources/Modules/AIUsageModule.swift`，可以直接照抄）。

## 支持的厂商

| 厂商 | 取数方式 | 需要什么 | 返回的窗口（`id`） |
|---|---|---|---|
| `claude` | 后台起 `claude`，发 `/usage` 读结果（约 10 秒） | `claude` 已登录 | `claude.session`（5 小时）、`claude.weekly`；有单模型额度时还有 `claude.weekly.<模型>`（如 `claude.weekly.fable`）或 `claude.weekly.model`（Sonnet/Opus） |
| `antigravity` | 调 `agy`（约 7 秒） | `agy` 已登录 | `antigravity.gemini-5h`、`antigravity.gemini-weekly`、`antigravity.3p-5h`、`antigravity.3p-weekly`（Claude/GPT）；Pro 等档位如有单独分组（如 Argon）也会原样带出，`group` 是分组名 |
| `grok` | 起 `grok agent stdio` 调 `_x.ai/billing`（约 3 秒） | `grok` 已登录 | `grok.weekly` |

> 个人 / AI Pro / Ultra 账号的 Gemini 额度只能从 `antigravity` 拿：谷歌 2026-06-18 起不再对这类账号开放 Gemini CLI 的配额接口。

不需要另外登录或授权。哪家的命令行没装、没登录，那一家就返回错误，不影响其他家。

---

## 在其他项目里使用

### 前提

- macOS 14+，Swift 6.2+（Xcode 26+）。
- **App 不能开 App Sandbox。** 它要启动 `claude` / `agy` / `grok` 子进程并读它们的本地状态，沙盒里做不到。Hardened Runtime 没问题（DockSidecar 就开着）。
- 体积：主程序会多大约 40MB（`CodexBarCore` 带了一百多家的代码和一个 JS 引擎）。

### 1. 加依赖

**只能按 `path:` / `branch:` / `revision:` 依赖，不能按版本号**（`from:` / `exact:` 会解析失败）。原因：CodexBar 自己按 commit 依赖了 Vortex，SwiftPM 不允许按版本号依赖这种包，这个限制会一路传下来。

我的项目都在 `~/Code/` 下，推荐直接用本地路径（DockSidecar 就是这么接的）：

```swift
// Package.swift
dependencies: [
    .package(path: "../AIUsageKit"),
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [.product(name: "AIUsageKit", package: "AIUsageKit")]),
]
```

要在没有本地 checkout 的地方编译，改用 git（私有仓库，需要本机 git 能访问 GitHub）：

```swift
.package(url: "https://github.com/XueshiQiao/AIUsageKit.git", branch: "main"),
// 或者固定到某个 commit：
.package(url: "https://github.com/XueshiQiao/AIUsageKit.git", revision: "<commit>"),
```

Xcode 工程：File → Add Package Dependencies → Add Local…，选 `~/Code/AIUsageKit`。

### 2. 打包时带上资源包（手工拼 .app 的必看）

`CodexBarCore` 带资源文件，SwiftPM 编译后会在产物目录里多出几个 `.bundle`（`CodexBar_CodexBarCore.bundle`、`SweetCookieKit_SweetCookieKit.bundle`、`swift-crypto_Crypto.bundle`）。

- **用 Xcode 工程编译**：Xcode 会自动拷进 App，不用管。
- **用 `swift build` + 脚本拼 `.app`**：必须把它们拷进 `Contents/Resources`。**漏了编译不报错，运行时一读资源就崩。** 照抄 DockSidecar 的 `build.sh`：

```bash
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)
cp "$BIN/MyApp" "$APP/Contents/MacOS/MyApp"
mkdir -p "$APP/Contents/Resources"
for b in "$BIN"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
# 然后照常 codesign（拷完 bundle 再签）
```

### 3. 取数

```swift
import AIUsageKit

// 取一家。失败会自动重试一次，单次默认 60 秒超时。
let usage = try await AIUsage.fetch(.claude)
print(usage.plan ?? "-")                // "Max"
for w in usage.windows {
    print(w.title,                       // "5-hour"
          w.usedPercent ?? -1,           // 已用 %
          w.elapsedPercent() ?? -1,      // 窗口时间已过 %
          w.resetsAt as Any)             // 重置时间
}

// 并发取多家，单家失败不影响别家。三家一起大约 10 秒（Claude 最慢）。
let results = await AIUsage.fetchAll([.claude, .antigravity, .grok])
switch results[.grok] {
case let .success(usage): print(usage.windows)
case let .failure(error): print(error.message)
case nil: break
}

// 按 id 取某个窗口
let weekly = usage.window(id: "claude.weekly")
```

### 4. 在 SwiftUI App 里用（推荐写法）

要点：
- **取数**放后台定时做，5 分钟一次足够（每次要起几个子进程，别太频繁）。
- **「时间已过」不要靠重新取数来更新**：`elapsedPercent(at:)` 是按传入时间现算的，UI 每 30 秒左右重算一次即可。
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

### 5. 数据结构

`ProviderUsage`：

| 字段 | 说明 |
|---|---|
| `provider` | `.claude` / `.antigravity` / `.grok` |
| `plan` | 订阅档位，如 `Max`、`SuperGrok`；Antigravity 拿不到，为 nil |
| `accountEmail` | 账号邮箱，可能为 nil |
| `windows` | `[UsageWindow]`，顺序固定（5 小时在前，每周在后；Antigravity 先 Gemini 组再 Claude/GPT 组） |
| `fetchedAt` | 数据时间 |
| `source` | CodexBar 实际用的取数策略，排查用，如 `claude.cli` |

`UsageWindow`：

| 字段 | 说明 |
|---|---|
| `id` | 稳定标识，见上面厂商表。可以拿来存「显示哪几个窗口」之类的设置 |
| `title` / `group` | 显示名（英文，界面上建议按 `kind` + `group` 自己拼中文名） / 分组名（Antigravity 的 `Gemini`、`Claude/GPT`；Claude 单模型额度的模型名；其余为 nil） |
| `kind` | `.session`（5 小时）/ `.weekly` / `.other` |
| `usedPercent` | 已用 0–100。**为 nil 表示厂商没给出用量**，不要当 0 显示 |
| `resetsAt` | 下次重置时间 |
| `windowSeconds` | 窗口长度（5 小时 = 18000，每周 = 604800） |
| `elapsedPercent(at:)` | 窗口时间已过百分比 = (now − (resetsAt − windowSeconds)) / windowSeconds，夹在 0–100。和 `usedPercent` 比就知道用得快不快 |
| `isPastReset(at:)` | 是否已过重置时间 |

所有类型都是 `Codable` + `Sendable`，可以直接存盘或跨线程传。

### 6. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 解析依赖报 `depends on an unstable-version package 'vortex'` | 用了 `from:` / `exact:`。改成 `path:` / `branch:` / `revision:` |
| 运行时一取数就崩，跟 `Bundle.module` 有关 | 资源包没拷进 `Contents/Resources`，见第 2 步 |
| 从 Finder / launchd 启动后某家报找不到命令 | GUI App 的 PATH 很短。已自动补上 `~/.local/bin`、`~/.grok/bin`、`~/.claude/local`、`/opt/homebrew/bin`、`/usr/local/bin`；装在别处的话改 `AIUsage.swift` 里的 `environment()` |
| 某家一直报未登录 / 过期 | 在终端里跑一次对应命令行（`claude` / `agy` / `grok`）重新登录 |
| Grok 偶尔超时 | CodexBar 里 Grok 的 billing 请求写死 3 秒超时，并发或网络慢时会超。已经自动重试一次 |
| 第一次 `swift build` 卡在拉 CodexBar 很久 | CodexBar 历史很大。网络慢时先浅克隆对应 tag，再 `swift package config set-mirror --original https://github.com/steipete/CodexBar.git --mirror <本地路径>`（只写进被 gitignore 的 `.swiftpm/`，每个根项目各配一次） |

---

## 命令行（调试用）

```bash
swift run aiusage                  # 三家都取，表格
swift run aiusage claude grok      # 只取指定的
swift run aiusage --json           # JSON，含 elapsedPercent
swift test                         # 单元测试（时间已过的算法、各家数据整理）
```

## 加新厂商

`CodexBarCore` 已经支持一百多家（DeepSeek、MiniMax 等）。加一家要改：

1. `Models.swift` 的 `AIProvider` 加一个 case；
2. `AIUsage.swift` 的 `route(for:)` 写它走哪条路径（只选不碰 Cookie 的：`.cli`、`.oauth`、`.api`）；需要 API key 的从环境变量给（CodexBar 认 `DEEPSEEK_API_KEY`、`MINIMAX_CODING_API_KEY` 这类）；
3. `UsageMapping.swift` 按它的数据形状整理窗口；
4. 跑一次 `swift run aiusage <名字>` 看实际返回，补一条单元测试。

## 升级 CodexBarCore

改 `Package.swift` 里的 `revision:`（找到目标 tag 对应的 commit）→ `swift build` → `swift test` → `swift run aiusage` 三家都看一遍 → 用它的项目各自 `swift package update AIUsageKit` 再编译。

上游接口确实会变：`main` 上有的 `AntigravityStatusProbe.isQuotaSummaryWindowID`，两天前的 v0.79.0 里就还没有。所以这一层尽量只用最基础的几个类型（`ProviderFetchContext`、`ProviderDescriptorRegistry`、`UsageSnapshot`、`RateWindow`、`NamedRateWindow`）。

## 其他

- 它会往钥匙串 / UserDefaults 写几条 `com.steipete.codexbar.*` 的缓存。
- 当前固定的上游版本：CodexBar v0.79.0（commit `b49d42eb`）。
