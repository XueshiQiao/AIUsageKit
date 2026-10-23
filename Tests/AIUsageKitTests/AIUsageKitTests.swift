import CodexBarCore
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
