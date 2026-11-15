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

actor FlagBox {
    private var flag = false
    func setTrue() { self.flag = true }
    func get() -> Bool { self.flag }
}

@Suite(.serialized)
struct AntigravityHardeningTests {
    func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIUsageKitAgyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func antigravityUsage(
        used: Double = 21,
        plan: String? = "Google AI Ultra",
        resetsAt: Date = Date().addingTimeInterval(3600),
        fetchedAt: Date = Date(),
        source: String = "antigravity.cli-https"
    ) -> ProviderUsage {
        ProviderUsage(
            provider: .antigravity,
            plan: plan,
            accountEmail: nil,
            windows: [
                UsageWindow(
                    id: "antigravity.gemini-5h",
                    title: "Gemini 5-hour",
                    group: "Gemini",
                    kind: .session,
                    usedPercent: used,
                    resetsAt: resetsAt,
                    windowSeconds: 5 * 3600
                ),
                UsageWindow(
                    id: "antigravity.gemini-weekly",
                    title: "Gemini weekly",
                    group: "Gemini",
                    kind: .weekly,
                    usedPercent: 11,
                    resetsAt: resetsAt.addingTimeInterval(86400),
                    windowSeconds: 7 * 86400
                ),
            ],
            fetchedAt: fetchedAt,
            source: source
        )
    }

    func writeStatusLineJSON(
        to url: URL,
        mtime: Date,
        planTier: String? = "Google AI Ultra",
        gemini5hRemaining: Double = 0.75,
        gemini5hReset: Date,
        otherReset: Date
    ) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var root: [String: Any] = [
            "quota": [
                "gemini-5h": [
                    "remaining_fraction": gemini5hRemaining,
                    "reset_time": iso.string(from: gemini5hReset),
                ],
                "gemini-weekly": [
                    "remaining_fraction": 0.88,
                    "reset_time": iso.string(from: otherReset),
                ],
                "3p-5h": [
                    "remaining_fraction": 1.0,
                    "reset_time": iso.string(from: otherReset),
                ],
                "3p-weekly": [
                    "remaining_fraction": 0.90,
                    "reset_time": iso.string(from: otherReset),
                ],
                "gemini-argon-wtu-weekly": [
                    "remaining_fraction": 0.95,
                    "reset_time": iso.string(from: otherReset),
                ],
            ],
        ]
        if let planTier {
            root["plan_tier"] = planTier
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    @Test func environmentSanitizesSSHEnvAndDisablesAutoUpdate() {
        let dirty: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "SSH_CONNECTION": "100.64.0.1 54321 100.64.0.2 22",
            "SSH_CLIENT": "100.64.0.1 54321 22",
            "SSH_TTY": "/dev/ttys009",
            "CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT": "1",
            "HOME": "/Users/tester",
        ]
        let clean = AIUsage.environment(from: dirty)
        #expect(clean["SSH_CONNECTION"] == nil)
        #expect(clean["SSH_CLIENT"] == nil)
        #expect(clean["SSH_TTY"] == nil)
        #expect(clean["CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT"] == nil)
        #expect(clean["AGY_CLI_DISABLE_AUTO_UPDATE"] == "true")
        #expect(clean["PATH"]?.contains("/opt/homebrew/bin") == true)
    }

    @Test func statusLineParsesPlanTierRelaxesMaxAgeAndSyncsCacheWhenNewerThanStoredAt() async throws {
        let base = self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let now = Date()
        let statusLineURL = base.appendingPathComponent("statusline.json")

        // 1. mtime 在 250s 前（超过旧版 120s，但在 max(180, 300)=300s 内），应命中并解析出 plan_tier
        try self.writeStatusLineJSON(
            to: statusLineURL,
            mtime: now.addingTimeInterval(-250),
            planTier: "Google AI Ultra",
            gemini5hRemaining: 0.72,
            gemini5hReset: now.addingTimeInterval(3600),
            otherReset: now.addingTimeInterval(86400)
        )
        let parsedWithin300 = SharedCache.readFreshAntigravityStatusLine(
            maxAge: 180,
            cachedStoredAt: nil,
            fileURL: statusLineURL,
            now: now
        )
        #expect(parsedWithin300?.plan == "Google AI Ultra")
        #expect(parsedWithin300?.windows.count == 5)
        #expect(parsedWithin300?.window(id: "antigravity.gemini-5h")?.usedPercent == 28)

        // 2. 若其中任一桶（如 gemini-5h）已过 resetsAt，即使其余 4 桶未过期也必须整份拒绝（不得漏桶放行）
        try self.writeStatusLineJSON(
            to: statusLineURL,
            mtime: now.addingTimeInterval(-10),
            planTier: "Google AI Ultra",
            gemini5hRemaining: 0.5,
            gemini5hReset: now.addingTimeInterval(-5),
            otherReset: now.addingTimeInterval(86400)
        )
        #expect(SharedCache.readFreshAntigravityStatusLine(
            maxAge: 240,
            cachedStoredAt: nil,
            fileURL: statusLineURL,
            now: now
        ) == nil)

        // 3. mtime 在 420s 前（超出 300s），但比本地缓存 storedAt (600s 前) 更新 -> fetchCoordinated 直接采纳并落盘，0 次 CLI
        let oldCached = self.antigravityUsage(used: 10, resetsAt: now.addingTimeInterval(3600), fetchedAt: now.addingTimeInterval(-600))
        SharedCache.writeSuccess(oldCached, now: now.addingTimeInterval(-600), baseDirectory: base)

        try self.writeStatusLineJSON(
            to: statusLineURL,
            mtime: now.addingTimeInterval(-420),
            planTier: "Google AI Ultra",
            gemini5hRemaining: 0.60,
            gemini5hReset: now.addingTimeInterval(3600),
            otherReset: now.addingTimeInterval(86400)
        )

        let cliCalls = Counter()
        let adopted = try await AIUsage.fetchCoordinated(
            .antigravity,
            maxAge: 240,
            timeout: 20,
            baseDirectory: base,
            statusLineURL: statusLineURL,
            antigravityActivityURLs: [],
            liveFetcher: {
                await cliCalls.increment()
                return self.antigravityUsage(used: 99)
            }
        )
        #expect(await cliCalls.value() == 0)
        #expect(adopted.plan == "Google AI Ultra")
        #expect(adopted.window(id: "antigravity.gemini-5h")?.usedPercent == 40)

        // 验证已同步写入 SharedCache 与详细决策日志
        let diskRecord = SharedCache.readRecord(for: .antigravity, baseDirectory: base)
        #expect(diskRecord?.plan == "Google AI Ultra")
        #expect(diskRecord?.source == "antigravity.statusline-file")
        #expect((diskRecord?.storedAt ?? .distantPast) >= now.addingTimeInterval(-2))

        let slLog = try String(contentsOf: base.appendingPathComponent("logs/usage.log"), encoding: .utf8)
        #expect(slLog.contains("STATUSLINE_HIT trigger=newer_than_cache"))
        #expect(slLog.contains("plan=\"Google AI Ultra\""))
    }

    @Test func idleGateReusesCacheWithoutTouchingStoredAtAndPenetratesOnActivityOrCeilingOrForce() async throws {
        let base = self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let now = Date()
        let storedAt = now.addingTimeInterval(-600) // 10 分钟前采样（超过 maxAge=240s，但未满 3600s）
        let seeded = self.antigravityUsage(used: 33, resetsAt: now.addingTimeInterval(3600), fetchedAt: storedAt)
        SharedCache.writeSuccess(seeded, now: storedAt, baseDirectory: base)

        // 模拟 agy -p 自己退出时在 storedAt + 2s（<= 3s 余量内）刷过一次汇总库
        let walURL = base.appendingPathComponent("conversation_summaries.db-wal")
        try Data("wal".utf8).write(to: walURL)
        try FileManager.default.setAttributes(
            [.modificationDate: storedAt.addingTimeInterval(2.0)],
            ofItemAtPath: walURL.path
        )

        let cliCalls = Counter()
        // A. 闲置轮询（maxAge: 240）-> 0ms 复用缓存，且不覆盖刷新 storedAt
        let reused = try await AIUsage.fetchCoordinated(
            .antigravity,
            maxAge: 240,
            timeout: 20,
            baseDirectory: base,
            statusLineURL: base.appendingPathComponent("missing-statusline.json"),
            antigravityActivityURLs: [walURL],
            liveFetcher: {
                await cliCalls.increment()
                return self.antigravityUsage(used: 55)
            }
        )
        #expect(await cliCalls.value() == 0)
        #expect(reused.windows.first?.usedPercent == 33)
        let afterIdleRecord = SharedCache.readRecord(for: .antigravity, baseDirectory: base)
        #expect(abs((afterIdleRecord?.storedAt ?? .distantPast).timeIntervalSince(storedAt)) < 1.0)

        // B. 手动强制刷新（maxAge: 0）-> 穿透闲置门控
        let forced = try await AIUsage.fetchCoordinated(
            .antigravity,
            maxAge: 0,
            timeout: 20,
            baseDirectory: base,
            statusLineURL: base.appendingPathComponent("missing-statusline.json"),
            antigravityActivityURLs: [walURL],
            liveFetcher: {
                await cliCalls.increment()
                return self.antigravityUsage(used: 44)
            }
        )
        #expect(await cliCalls.value() == 1)
        #expect(forced.windows.first?.usedPercent == 44)

        // C. 重新种入 10 分钟前缓存，但汇总库在 storedAt + 10s 有新会话写入 -> 触发真实查询
        SharedCache.writeSuccess(seeded, now: storedAt, baseDirectory: base)
        try FileManager.default.setAttributes(
            [.modificationDate: storedAt.addingTimeInterval(10.0)],
            ofItemAtPath: walURL.path
        )
        let afterActivity = try await AIUsage.fetchCoordinated(
            .antigravity,
            maxAge: 240,
            timeout: 20,
            baseDirectory: base,
            statusLineURL: base.appendingPathComponent("missing-statusline.json"),
            antigravityActivityURLs: [walURL],
            liveFetcher: {
                await cliCalls.increment()
                return self.antigravityUsage(used: 66)
            }
        )
        #expect(await cliCalls.value() == 2)
        #expect(afterActivity.windows.first?.usedPercent == 66)

        // D. 超过 60 分钟（3605s）兜底上限 -> 即使无汇总文件活动也穿透刷新
        let expiredCeilingAt = now.addingTimeInterval(-3605)
        SharedCache.writeSuccess(seeded, now: expiredCeilingAt, baseDirectory: base)
        _ = try await AIUsage.fetchCoordinated(
            .antigravity,
            maxAge: 240,
            timeout: 20,
            baseDirectory: base,
            statusLineURL: base.appendingPathComponent("missing-statusline.json"),
            antigravityActivityURLs: [],
            liveFetcher: {
                await cliCalls.increment()
                return self.antigravityUsage(used: 77)
            }
        )
        #expect(await cliCalls.value() == 3)

        let idleLog = try String(contentsOf: base.appendingPathComponent("logs/usage.log"), encoding: .utf8)
        #expect(idleLog.contains("IDLE_REUSE action=skip_agy"))
        #expect(idleLog.contains("summaryFile=conversation_summaries.db-wal"))
        #expect(idleLog.contains("LIVE_SPAWN_REASON reason=force_refresh(maxAge=0)"))
        #expect(idleLog.contains("LIVE_SPAWN_REASON reason=activity_detected(file=conversation_summaries.db-wal"))
        #expect(idleLog.contains("LIVE_SPAWN_REASON reason=idle_ceiling_60m"))
    }

    @Test func offlineFallbackAndEmptyWindowsAreRejectedPreservingPreviousCacheWith120sBackoff() async throws {
        let base = self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let now = Date()
        let oldAt = now.addingTimeInterval(-4000) // 超过 60m 上限以触发 liveFetcher
        let validCached = self.antigravityUsage(used: 48, resetsAt: now.addingTimeInterval(3600), fetchedAt: oldAt)
        SharedCache.writeSuccess(validCached, now: oldAt, baseDirectory: base)

        // 模拟 CodexBarCore 回退到 antigravity.offline（空窗口）
        await #expect(throws: AIUsageError.self) {
            _ = try await AIUsage.fetchCoordinated(
                .antigravity,
                maxAge: 240,
                timeout: 20,
                baseDirectory: base,
                statusLineURL: base.appendingPathComponent("missing-statusline.json"),
                antigravityActivityURLs: [],
                liveFetcher: {
                    ProviderUsage(
                        provider: .antigravity,
                        plan: nil,
                        accountEmail: nil,
                        windows: [],
                        fetchedAt: Date(),
                        source: "antigravity.offline"
                    )
                }
            )
        }

        // 旧有效窗口必须完整保留，且退避时长为 120s
        let preserved = SharedCache.readRecord(for: .antigravity, baseDirectory: base)
        #expect(preserved?.windows.first?.usedPercent == 48)
        #expect(preserved?.source == "antigravity.cli-https")
        #expect(preserved?.lastErrorKind == "failed")
        let retryRemaining = (preserved?.retryAfter ?? .distantPast).timeIntervalSinceNow
        #expect(retryRemaining > 100 && retryRemaining <= 125)

        let offlineLog = try String(contentsOf: base.appendingPathComponent("logs/usage.log"), encoding: .utf8)
        #expect(offlineLog.contains("OFFLINE_GUARD_REJECTED strategyID=antigravity.offline"))
        #expect(offlineLog.contains("preservedCachedWindows=2"))
    }

    @Test func retryLimitedToGrokAndBoundedFetchPropagatesCancellation() async throws {
        let base = self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(AIUsage.effectiveLiveTimeout(for: .antigravity, requested: 60) == 20)
        #expect(AIUsage.effectiveLiveTimeout(for: .antigravity, requested: 8) == 8)
        #expect(AIUsage.effectiveLiveTimeout(for: .claude, requested: 60) == 60)

        // 1. Antigravity 报错不重试（仅执行 1 次）
        let agyAttempts = Counter()
        await #expect(throws: AIUsageError.self) {
            _ = try await AIUsage.runWithProviderRetry(.antigravity, baseDirectory: base) {
                await agyAttempts.increment()
                throw AIUsageError(provider: .antigravity, message: "auth error", kind: .failed)
            }
        }
        #expect(await agyAttempts.value() == 1)

        // 2. Grok 首次报错会重试第 2 次并成功
        let grokAttempts = Counter()
        let grokOK = try await AIUsage.runWithProviderRetry(.grok, baseDirectory: base) {
            await grokAttempts.increment()
            if await grokAttempts.value() == 1 {
                throw AIUsageError(provider: .grok, message: "3s billing timeout", kind: .failed)
            }
            return ProviderUsage(
                provider: .grok,
                plan: "SuperGrok",
                accountEmail: nil,
                windows: [],
                fetchedAt: Date(),
                source: "grok.cli"
            )
        }
        #expect(await grokAttempts.value() == 2)
        #expect(grokOK.plan == "SuperGrok")

        // 3. runBounded 超时时立即调用 worker.cancel()，向工作闭包传播取消信号
        let cancelledFlag = FlagBox()
        await #expect(throws: AIUsageError.self) {
            _ = try await AIUsage.runBounded(.antigravity, timeout: 0.15, reapNames: []) {
                try await withTaskCancellationHandler {
                    try await Task.sleep(for: .seconds(10))
                    return self.antigravityUsage()
                } onCancel: {
                    Task { await cancelledFlag.setTrue() }
                }
            }
        }
        try await Task.sleep(for: .milliseconds(60))
        #expect(await cancelledFlag.get() == true)
    }
}
