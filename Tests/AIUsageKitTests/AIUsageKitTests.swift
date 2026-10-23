import CodexBarCore
import Darwin
import Foundation
import Testing
@testable import AIUsageKit

struct ElapsedPercentTests {
    let reset = Date(timeIntervalSince1970: 1_000_000)

    func window(seconds: TimeInterval?, resetsAt: Date?) -> UsageWindow {
        UsageWindow(id: "t", title: "t", group: nil, kind: .session, usedPercent: 30, resetsAt: resetsAt, windowSeconds: seconds)
    }

    @Test func fiveHourWindowFourHoursLeftIsTwentyPercent() {
        let w = self.window(seconds: 5 * 3600, resetsAt: self.reset)
        let now = self.reset.addingTimeInterval(-4 * 3600)
        #expect(abs(w.elapsedPercent(at: now)! - 20) < 0.0001)
    }

    @Test func weeklyWindowHalfway() {
        let w = self.window(seconds: 7 * 86400, resetsAt: self.reset)
        let now = self.reset.addingTimeInterval(-3.5 * 86400)
        #expect(abs(w.elapsedPercent(at: now)! - 50) < 0.0001)
    }

    @Test func clampsOutsideWindow() {
        let w = self.window(seconds: 3600, resetsAt: self.reset)
        #expect(w.elapsedPercent(at: self.reset.addingTimeInterval(60)) == 100)
        #expect(w.elapsedPercent(at: self.reset.addingTimeInterval(-7200)) == 0)
        #expect(w.isPastReset(at: self.reset.addingTimeInterval(1)))
    }

    @Test func missingDataGivesNil() {
        #expect(self.window(seconds: nil, resetsAt: self.reset).elapsedPercent() == nil)
        #expect(self.window(seconds: 3600, resetsAt: nil).elapsedPercent() == nil)
    }
}

struct MappingTests {
    func snapshot(_ json: String) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsageSnapshot.self, from: Data(json.utf8))
    }

    @Test func antigravityUsesAllGroupsIncludingArgon() throws {
        let s = try self.snapshot("""
        {"updatedAt":"2026-10-22T14:00:00Z",
         "primary":{"usedPercent":34,"windowMinutes":10080,"resetsAt":"2026-10-27T06:55:44Z"},
         "secondary":{"usedPercent":57,"windowMinutes":10080,"resetsAt":"2026-10-28T10:52:59Z"},
         "extraRateWindows":[
          {"id":"antigravity-quota-summary-gemini-5h","title":"Gemini 5-hour","usageKnown":true,
           "window":{"usedPercent":3,"windowMinutes":300,"resetsAt":"2026-10-22T19:29:07Z"}},
          {"id":"antigravity-quota-summary-gemini-weekly","title":"Gemini weekly","usageKnown":true,
           "window":{"usedPercent":34,"windowMinutes":10080,"resetsAt":"2026-10-27T06:55:44Z"}},
          {"id":"antigravity-quota-summary-3p-5h","title":"Claude/GPT 5-hour","usageKnown":true,
           "window":{"usedPercent":23,"windowMinutes":300,"resetsAt":"2026-10-22T19:11:39Z"}},
          {"id":"antigravity-quota-summary-3p-weekly","title":"Claude/GPT weekly","usageKnown":true,
           "window":{"usedPercent":57,"windowMinutes":10080,"resetsAt":"2026-10-28T10:52:59Z"}},
          {"id":"antigravity-quota-summary-argon-weekly","title":"Gemini 4 Argon weekly","usageKnown":false,
           "window":{"usedPercent":0,"windowMinutes":10080,"resetsAt":"2026-10-28T00:00:00Z"}}
         ]}
        """)
        let windows = UsageMapping.windows(for: .antigravity, snapshot: s)
        #expect(windows.map(\.id) == [
            "antigravity.gemini-5h", "antigravity.gemini-weekly",
            "antigravity.3p-5h", "antigravity.3p-weekly", "antigravity.argon-weekly",
        ])
        #expect(windows[0].group == "Gemini" && windows[0].kind == .session)
        #expect(windows[3].group == "Claude/GPT" && windows[3].kind == .weekly)
        #expect(windows[4].group == "Gemini 4 Argon")
        #expect(windows[4].usedPercent == nil) // usageKnown=false 不能当 0% 显示
    }

    @Test func claudeSessionWeeklyAndScopedModel() throws {
        let s = try self.snapshot("""
        {"updatedAt":"2026-10-22T14:00:00Z",
         "primary":{"usedPercent":1,"windowMinutes":300,"resetsAt":"2026-10-22T15:10:00Z"},
         "secondary":{"usedPercent":11,"windowMinutes":10080,"resetsAt":"2026-10-29T04:00:00Z"},
         "extraRateWindows":[
          {"id":"claude-weekly-scoped-fable","title":"Fable only","usageKnown":true,
           "window":{"usedPercent":40,"windowMinutes":10080,"resetsAt":"2026-10-29T04:00:00Z"}}
         ]}
        """)
        let windows = UsageMapping.windows(for: .claude, snapshot: s)
        #expect(windows.map(\.id) == ["claude.session", "claude.weekly", "claude.weekly.fable"])
        #expect(windows[2].group == "Fable" && windows[2].usedPercent == 40)
    }
}

struct SharedCacheTests {
    func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIUsageKitTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func sampleUsage(
        provider: AIProvider = .claude,
        email: String? = "secret@example.com",
        used: Double = 42,
        resetsAt: Date = Date().addingTimeInterval(3600),
        fetchedAt: Date = Date()
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            plan: "Max",
            accountEmail: email,
            windows: [
                UsageWindow(
                    id: "\(provider.rawValue).session",
                    title: "5-hour",
                    group: nil,
                    kind: .session,
                    usedPercent: used,
                    resetsAt: resetsAt,
                    windowSeconds: 18000
                ),
            ],
            fetchedAt: fetchedAt,
            source: "\(provider.rawValue).cli"
        )
    }

    @Test func stripsAccountEmailOnDiskAndIsolatesProviders() throws {
        let base = self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let now = Date()
        let claude = self.sampleUsage(provider: .claude, email: "private-user@anthropic.com", used: 25, fetchedAt: now)
        SharedCache.writeSuccess(claude, now: now, baseDirectory: base)

        // 1. 磁盘原始 JSON 绝不包含邮箱字符串
        let fileURL = SharedCache.cacheFileURL(for: .claude, baseDirectory: base)
        let rawText = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!rawText.contains("private-user@anthropic.com"))
        #expect(!rawText.contains("accountEmail"))

        // 2. 读出后 accountEmail 为 nil，其它字段完整
        let record = SharedCache.readRecord(for: .claude, baseDirectory: base)
        let restored = record?.toProviderUsage()
        #expect(restored != nil)
        #expect(restored?.accountEmail == nil)
        #expect(restored?.plan == "Max")
        #expect(restored?.windows.first?.usedPercent == 25)

        // 3. 其它 provider 的缓存文件完全不存在（松耦合隔离）
        #expect(SharedCache.readRecord(for: .grok, baseDirectory: base) == nil)
    }

    @Test func evaluateFreshnessAndJustResetWithoutInfiniteLoop() {
        let base = self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let resetAt = t0.addingTimeInterval(60) // t0 + 60s 重置
        let usage = self.sampleUsage(provider: .claude, resetsAt: resetAt, fetchedAt: t0)
        SharedCache.writeSuccess(usage, now: t0, baseDirectory: base)

        let recordBeforeReset = SharedCache.readRecord(for: .claude, baseDirectory: base)
        // 在 t0 + 30s（未过重置时间，age=30s < maxAge=180s）-> fresh
        #expect(SharedCache.evaluate(recordBeforeReset, maxAge: 180, now: t0.addingTimeInterval(30))
            == .fresh(age: 30, suppressedResetWindowID: nil))

        // 在 t0 + 65s（刚过重置时间，且 storedAt = t0 < resetAt）-> stale(window_reset)
        #expect(SharedCache.evaluate(recordBeforeReset, maxAge: 180, now: t0.addingTimeInterval(65))
            == .stale(reason: "window_reset(claude.session)"))

        // 假设在 t0 + 70s 重新取了一次，但服务端时钟慢了，返回的 resetsAt 依然是旧的 resetAt (t0 + 60s)
        // 因为 storedAt (t0 + 70s) >= resetAt (t0 + 60s)，不会死循环判 stale，而是 fresh 并标注 suppressed
        let tAfter = t0.addingTimeInterval(70)
        SharedCache.writeSuccess(usage, now: tAfter, baseDirectory: base)
        let recordAfterReset = SharedCache.readRecord(for: .claude, baseDirectory: base)
        #expect(SharedCache.evaluate(recordAfterReset, maxAge: 180, now: t0.addingTimeInterval(80))
            == .fresh(age: 10, suppressedResetWindowID: "claude.session"))
    }

    @Test func doubleCheckServesCacheEvenOnForceRefreshWhenPeerJustUpdated() async throws {
        let base = self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        // 模拟另一个进程先持有了 grok.lock
        let lockURL = SharedCache.lockFileURL(for: .grok, baseDirectory: base)
        let peerFD = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        #expect(peerFD >= 0)
        #expect(flock(peerFD, LOCK_EX | LOCK_NB) == 0)

        let counter = Counter()

        // 250ms 后模拟另一个进程完成了 CLI 刷新、写入缓存并释放锁
        let peerUsage = self.sampleUsage(provider: .grok, used: 77)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(250))
            SharedCache.writeSuccess(peerUsage, now: Date(), baseDirectory: base)
            _ = flock(peerFD, LOCK_UN)
            _ = close(peerFD)
        }

        // 当前进程以 maxAge: 0（强制刷新）发起请求，应当等待 peer 释放锁并在 Double-Check 命中刚刚写入的缓存，不触发 liveFetcher
        let result = try await AIUsage.fetchCoordinated(
            .grok,
            maxAge: 0,
            timeout: 10,
            baseDirectory: base,
            liveFetcher: {
                await counter.increment()
                return self.sampleUsage(provider: .grok, used: 99)
            }
        )

        #expect(result.windows.first?.usedPercent == 77)
        #expect(await counter.value() == 0)

        // 检查日志是否完整记录了 LOCK_WAIT -> LOCK_ACQUIRED -> CACHE_HIT_AFTER_WAIT
        let logURL = base.appendingPathComponent("logs/usage.log")
        let logText = try String(contentsOf: logURL, encoding: .utf8)
        #expect(logText.contains("LOCK_WAIT"))
        #expect(logText.contains("LOCK_ACQUIRED mode=after_wait"))
        #expect(logText.contains("CACHE_HIT_AFTER_WAIT reason=peer_just_updated"))
    }
}

actor Counter {
    private var count = 0
    func increment() { self.count += 1 }
    func value() -> Int { self.count }
}
