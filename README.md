# AIUsageKit

English | [中文](README.zh-CN.md)

A small Swift package that reads the **real subscription usage** of your AI coding tools — for every quota window it returns the **used percentage**, the **reset time**, and **how much of the window has elapsed**, so you can tell at a glance whether you are burning quota faster than time passes.

| Provider | Windows |
|---|---|
| **Claude** (Claude Code Pro / Max) | 5-hour, weekly, plus model-scoped weekly limits when your plan has them |
| **Antigravity** (Google) | Gemini 5-hour / weekly, Claude & GPT ("third-party") 5-hour / weekly, plus any extra group your tier has (e.g. a separate Argon quota) |
| **Grok** (SuperGrok) | weekly |

It is a thin, opinionated wrapper around `CodexBarCore`, the library inside [CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger (MIT). The heavy lifting — talking to each provider — is CodexBar's. This package only:

1. **Pins one safe data path per provider.** Every provider is read through its own official CLI (`claude`, `agy`, `grok`). No browser cookies, no reading Claude Code's Keychain item, no permission prompts. Token refresh stays with each CLI.
2. **Normalizes the result** into one simple `UsageWindow` type.
3. **Absorbs upstream churn.** `CodexBarCore` ships almost daily and its API is not stable; the version is pinned here so your app doesn't have to care.

> Personal project, shared as-is. It works for me on macOS 26 with the CLIs listed below; no promise of support or prompt updates when providers change.

## Requirements

- macOS 14+, Swift 6.2+ (Xcode 26+).
- The provider CLIs you want to read must be **installed and signed in** on the machine:

  | Provider | CLI | Typical duration |
  |---|---|---|
  | `claude` | [Claude Code](https://docs.claude.com/en/docs/claude-code) — runs `claude` in a hidden pseudo-terminal and reads `/usage` | ~10 s |
  | `antigravity` | [Antigravity CLI](https://antigravity.google) `agy` | ~7 s |
  | `grok` | [Grok Build](https://github.com/xai-org/grok-build) `grok` — calls `_x.ai/billing` over `grok agent stdio` | ~3 s |

  A provider whose CLI is missing or signed out returns an error; the others are unaffected.
- **Your app must not be sandboxed** — it needs to launch those CLIs. Hardened Runtime is fine.
- Adds roughly **40 MB** to your binary (`CodexBarCore` includes 100+ providers and a JS engine).

> Google stopped serving Gemini CLI quota for individual / AI Pro / Ultra accounts on 2026-06-18, so for those accounts Gemini usage is only available through `antigravity`.

## Installation

**Depend on it by `branch:`, `revision:` or `path:` — not by version.** `from:` / `exact:` fail to resolve, because CodexBar itself depends on a package by commit and SwiftPM forbids version-based dependencies on such packages.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/XueshiQiao/AIUsageKit.git", branch: "main"),
    // or pin a commit:  revision: "<sha>"
    // or a local checkout:  .package(path: "../AIUsageKit")
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [.product(name: "AIUsageKit", package: "AIUsageKit")]),
]
```

In Xcode: *File → Add Package Dependencies…* and enter the URL with the `main` branch rule.

### Bundling resources (only if you assemble the `.app` yourself)

`CodexBarCore` ships resources, so SwiftPM produces a few `.bundle`s next to your binary (`CodexBar_CodexBarCore.bundle`, `SweetCookieKit_SweetCookieKit.bundle`, `swift-crypto_Crypto.bundle`).

- **Xcode project:** copied automatically, nothing to do.
- **`swift build` + a script that builds the `.app`:** copy them into `Contents/Resources`. **If you forget, it still compiles but crashes at runtime** the first time a resource is read.

```bash
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)
cp "$BIN/MyApp" "$APP/Contents/MacOS/MyApp"
mkdir -p "$APP/Contents/Resources"
for b in "$BIN"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
# then codesign as usual (after copying the bundles)
```

## Usage

```swift
import AIUsageKit

// One provider. Retries once on failure; 60 s timeout per attempt by default.
let usage = try await AIUsage.fetch(.claude)
print(usage.plan ?? "-")                 // "Max"
for w in usage.windows {
    print(w.title,                        // "5-hour"
          w.usedPercent ?? -1,            // used %
          w.elapsedPercent() ?? -1,       // % of the window already elapsed
          w.resetsAt as Any)              // next reset
}

// Several providers concurrently; one failing doesn't affect the others (~10 s total).
let results = await AIUsage.fetchAll([.claude, .antigravity, .grok])
switch results[.grok] {
case let .success(usage): print(usage.windows)
case let .failure(error): print(error.message)
case nil: break
}

// A specific window by its stable id
let weekly = usage.window(id: "claude.weekly")
```

### In a SwiftUI app

- **Fetch in the background every ~5 minutes.** Each fetch spawns CLI processes; don't poll aggressively.
- **Don't re-fetch to update the elapsed percentage.** `elapsedPercent(at:)` is computed from the time you pass in — just re-evaluate it every ~30 s.
- When a window passes `resetsAt`, the stored numbers are pre-reset: show 0 % and trigger a refresh (`isPastReset(at:)`).
- On failure, keep the last good data and just flag the error.

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
                case let .failure(error): errors[provider] = error.message   // keep the old data
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
            Text(used.map { "\(Int($0))%" } ?? "–")                        // nil = unknown, don't show 0 %
            Text(window.elapsedPercent(at: now).map { "\(Int($0))% elapsed" } ?? "")
        }
    }
}
```

## Data model

`ProviderUsage`

| Field | Meaning |
|---|---|
| `provider` | `.claude` / `.antigravity` / `.grok` |
| `plan` | Subscription tier, e.g. `Max`, `SuperGrok`. `nil` for Antigravity |
| `accountEmail` | Account email if known (kept in memory only; never written anywhere by this package) |
| `windows` | `[UsageWindow]`, stable order: 5-hour before weekly; for Antigravity the Gemini group first |
| `fetchedAt` | When the data was captured |
| `source` | The CodexBar strategy that produced it (debugging), e.g. `claude.cli` |

`UsageWindow`

| Field | Meaning |
|---|---|
| `id` | Stable id, see below. Safe to persist (e.g. "which windows to show") |
| `title` / `group` | English display title / group name (`Gemini`, `Claude/GPT`, a model name for Claude's model-scoped limits, otherwise `nil`) |
| `kind` | `.session` (5-hour) / `.weekly` / `.other` |
| `usedPercent` | 0–100. **`nil` means the provider didn't report usage** — don't render it as 0 % |
| `resetsAt` | Next reset |
| `windowSeconds` | Window length (5 h = 18000, 1 week = 604800) |
| `elapsedPercent(at:)` | `(now − (resetsAt − windowSeconds)) / windowSeconds`, clamped to 0–100 |
| `isPastReset(at:)` | Whether `resetsAt` has passed |

All types are `Codable` and `Sendable`.

Window ids:

| Provider | ids |
|---|---|
| `claude` | `claude.session`, `claude.weekly`; model-scoped limits as `claude.weekly.<model>` (e.g. `claude.weekly.fable`) or `claude.weekly.model` (Sonnet/Opus) |
| `antigravity` | `antigravity.gemini-5h`, `antigravity.gemini-weekly`, `antigravity.3p-5h`, `antigravity.3p-weekly`; extra groups keep their own id and `group` name |
| `grok` | `grok.weekly` |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Resolution fails with `depends on an unstable-version package 'vortex'` | You used `from:` / `exact:`. Use `branch:` / `revision:` / `path:` |
| Crash on first fetch, mentioning `Bundle.module` | Resource bundles not copied into `Contents/Resources` (see *Bundling resources*) |
| A provider says signed out / expired | Run its CLI once in a terminal (`claude`, `agy`, `grok`) and sign in again |
| Command not found when launched from Finder / launchd | GUI apps get a short `PATH`. The package adds `~/.local/bin`, `~/.grok/bin`, `~/.claude/local`, `/opt/homebrew/bin`, `/usr/local/bin`; edit `environment()` in `AIUsage.swift` if your CLIs live elsewhere |
| Grok occasionally times out | CodexBar hard-codes a 3 s timeout for Grok's billing call; it can trip under concurrency or slow networks. The package retries once automatically |
| First `swift build` hangs fetching CodexBar | Its git history is large. On a slow network, shallow-clone the pinned tag and point SwiftPM at it: `swift package config set-mirror --original https://github.com/steipete/CodexBar.git --mirror <local path>` (stored in the git-ignored `.swiftpm/`) |

## Debug CLI

```bash
swift run aiusage                  # all providers, table
swift run aiusage claude grok      # selected providers
swift run aiusage --json           # JSON, including elapsedPercent
swift test                         # unit tests
```

## Adding a provider

`CodexBarCore` already supports 100+ providers (DeepSeek, MiniMax, …). To add one:

1. Add a case to `AIProvider` in `Models.swift`.
2. Choose its data path in `route(for:)` in `AIUsage.swift` — only cookie-free modes (`.cli`, `.oauth`, `.api`). API keys go in through environment variables (CodexBar reads e.g. `DEEPSEEK_API_KEY`, `MINIMAX_CODING_API_KEY`).
3. Map its snapshot to windows in `UsageMapping.swift`.
4. Check real output with `swift run aiusage <name>` and add a unit test.

## Upgrading CodexBarCore

Change the `revision:` in `Package.swift` (the commit of the target tag) → `swift build` → `swift test` → `swift run aiusage` for every provider. The upstream API really does move: `AntigravityStatusProbe.isQuotaSummaryWindowID` exists on `main` but not in v0.79.0, two days older. So this package sticks to the most basic types (`ProviderFetchContext`, `ProviderDescriptorRegistry`, `UsageSnapshot`, `RateWindow`, `NamedRateWindow`).

Currently pinned: CodexBar **v0.79.0** (commit `b49d42eb`).

## Notes

- CodexBarCore may write a few `com.steipete.codexbar.*` cache entries to the Keychain / UserDefaults.
- Not affiliated with Anthropic, Google, xAI or CodexBar.

## License

[MIT](LICENSE). `CodexBarCore` is MIT-licensed by Peter Steinberger.
