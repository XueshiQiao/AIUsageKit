import Darwin
import Foundation

/// 跨进程共享缓存与单飞互斥锁（`~/Library/Caches/AIUsageKit/v1/`）。
///
/// 核心机制：
/// - **按厂商完全解耦**：每家独立拥有 `<provider>.json` 和 `<provider>.lock`。
///   App A 只关心 `[.claude, .grok]` 时完全不碰 `antigravity`，不同 App 关注不同子集时自动在交集上共享缓存、在差集上互不干扰。
/// - **专用脱敏磁盘结构（`DiskRecord`）**：不直接编码 `ProviderUsage`，从结构体层面排除 `accountEmail` 等任何个人敏感字段。
/// - **本机写盘墙钟 `storedAt`**：缓存新鲜度和 `justReset` 一律对比本机写入时间 `storedAt`，避免上游服务端 `fetchedAt` 滞后造成误判。
/// - **失败退避记录（`lastAttemptAt` / `retryAfter`）**：当持锁进程 CLI 失败时，保留旧快照并写入 `retryAfter`（默认 20 秒），
///   防止等锁队列里的其它 App 在同一秒排着队再把失败的 CLI 重跑几遍。
/// - **安全的文件锁（`O_CLOEXEC` + 非阻塞轮询）**：
///   `open(..., O_CREAT | O_RDWR | O_CLOEXEC, 0o600)` 确保派生的 `claude` / `agy` / `grok` 子进程绝不会继承锁 fd；
///   使用 `flock(LOCK_EX | LOCK_NB)` + `Task.sleep` 避免阻塞 Swift Concurrency 协作线程池。
enum SharedCache {
    static let didUpdateNotification = Notification.Name("me.xueshi.AIUsageKit.didUpdate")
    static let failureBackoffSeconds: TimeInterval = 20
    static let antigravityFailureBackoffSeconds: TimeInterval = 120
    static let antigravityIdleCeilingSeconds: TimeInterval = 3600
    static let antigravityActivityGraceSeconds: TimeInterval = 3.0
    private static let maxRecordBytes = 256 * 1024

    static func failureBackoffSeconds(for provider: AIProvider) -> TimeInterval {
        switch provider {
        case .antigravity: Self.antigravityFailureBackoffSeconds
        case .claude, .grok: Self.failureBackoffSeconds
        }
    }

    static var defaultAntigravityStatusLineURL: URL {
        URL(fileURLWithPath: "/tmp/agy_statusline_input.json", isDirectory: false)
    }

    static var defaultAntigravityActivityURLs: [URL] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        return [
            dir.appendingPathComponent("conversation_summaries.db-wal", isDirectory: false),
            dir.appendingPathComponent("conversation_summaries.db", isDirectory: false),
            dir.appendingPathComponent("jetbox_summaries_proto.pb", isDirectory: false),
        ]
    }

    static var defaultBaseDirectoryURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent("AIUsageKit", isDirectory: true)
    }

    private static func v1Directory(baseDirectory: URL?) -> URL {
        let root = baseDirectory ?? Self.defaultBaseDirectoryURL
        let dir = root.appendingPathComponent("v1", isDirectory: true)
        UsageLogger.ensureDirectory(dir)
        return dir
    }

    static func cacheFileURL(for provider: AIProvider, baseDirectory: URL? = nil) -> URL {
        Self.v1Directory(baseDirectory: baseDirectory)
            .appendingPathComponent("\(provider.rawValue).json", isDirectory: false)
    }

    static func lockFileURL(for provider: AIProvider, baseDirectory: URL? = nil) -> URL {
        Self.v1Directory(baseDirectory: baseDirectory)
            .appendingPathComponent("\(provider.rawValue).lock", isDirectory: false)
    }

    /// 落盘专用结构（不含 `accountEmail`）。
    struct DiskRecord: Codable, Equatable, Sendable {
        var provider: AIProvider
        var plan: String?
        var windows: [UsageWindow]
        /// 上游快照带的时间戳。
        var fetchedAt: Date?
        /// 本机成功写入这份快照的墙钟时间（判断 `maxAge` 与 `justReset` 的唯一基准）。
        var storedAt: Date?
        var source: String?
        /// 写入该快照的进程标识，例如 `"Attaché:41820"`。
        var fetchedBy: String?
        /// 最近一次尝试 CLI 取数的时间（无论成功失败）。
        var lastAttemptAt: Date?
        /// 最近一次失败后的退避截止时间。
        var retryAfter: Date?
        /// 最近一次失败的分类码（仅限 `"failed"` / `"timeout"` / `"busy"`，不含任何错误详情文本）。
        var lastErrorKind: String?

        var hasSnapshot: Bool {
            self.storedAt != nil && self.fetchedAt != nil && self.source != nil
        }

        func toProviderUsage() -> ProviderUsage? {
            guard let fetchedAt, let source, self.storedAt != nil else { return nil }
            return ProviderUsage(
                provider: self.provider,
                plan: self.plan,
                accountEmail: nil,
                windows: self.windows,
                fetchedAt: fetchedAt,
                source: source
            )
        }
    }

    // MARK: - 无锁读取与原子写入

    static func readRecord(for provider: AIProvider, baseDirectory: URL? = nil) -> DiskRecord? {
        let url = Self.cacheFileURL(for: provider, baseDirectory: baseDirectory)
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count <= Self.maxRecordBytes
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(DiskRecord.self, from: data),
              record.provider == provider
        else { return nil }
        return record
    }

    static func writeSuccess(
        _ usage: ProviderUsage,
        now: Date = Date(),
        baseDirectory: URL? = nil
    ) {
        let record = DiskRecord(
            provider: usage.provider,
            plan: usage.plan,
            windows: usage.windows,
            fetchedAt: usage.fetchedAt,
            storedAt: now,
            source: usage.source,
            fetchedBy: UsageLogger.processTag,
            lastAttemptAt: now,
            retryAfter: nil,
            lastErrorKind: nil
        )
        Self.writeRecord(record, for: usage.provider, baseDirectory: baseDirectory)
    }

    static func writeFailure(
        provider: AIProvider,
        errorKind: AIUsageError.Kind,
        now: Date = Date(),
        backoff: TimeInterval? = nil,
        baseDirectory: URL? = nil
    ) {
        let resolvedBackoff = backoff ?? Self.failureBackoffSeconds(for: provider)
        var record = Self.readRecord(for: provider, baseDirectory: baseDirectory)
            ?? DiskRecord(provider: provider, plan: nil, windows: [])
        record.lastAttemptAt = now
        record.retryAfter = now.addingTimeInterval(resolvedBackoff)
        record.lastErrorKind = errorKind.rawValue
        Self.writeRecord(record, for: provider, baseDirectory: baseDirectory)
    }

    private static func writeRecord(
        _ record: DiskRecord,
        for provider: AIProvider,
        baseDirectory: URL?
    ) {
        let dir = Self.v1Directory(baseDirectory: baseDirectory)
        let targetURL = dir.appendingPathComponent("\(provider.rawValue).json", isDirectory: false)
        let tempURL = dir.appendingPathComponent(".\(provider.rawValue).json.tmp.\(getpid()).\(UUID().uuidString)", isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }

        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        _ = fchmod(fd, 0o600)
        let wroteAll: Bool = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return false }
            return Darwin.write(fd, base, raw.count) == raw.count
        }
        _ = close(fd)
        guard wroteAll else {
            _ = unlink(tempURL.path)
            return
        }
        if rename(tempURL.path, targetURL.path) != 0 {
            _ = unlink(tempURL.path)
        }
    }

    // MARK: - 新鲜度与重置判定

    enum FreshnessEvaluation: Equatable {
        case fresh(age: TimeInterval, suppressedResetWindowID: String?)
        case stale(reason: String)
    }

    /// 评估缓存对于给定 `maxAge` 和 `now` 是否算新鲜。
    ///
    /// - 规则 1：`maxAge <= 0` 一律视为调用方要求强制刷新（`reason = "force_refresh"`）。
    /// - 规则 2：`age = max(0, now - storedAt)`，若 `age >= maxAge` 则过期。
    /// - 规则 3（`justReset`）：若某个窗口存在 `resetsAt <= now`：
    ///   - 如果 `storedAt < resetsAt` 且 `(lastAttemptAt ?? .distantPast) < resetsAt`，说明窗口刚跨过重置点且重置后还没试过，判定为过期（`window_reset:<id>`）；
    ///   - 如果 `storedAt >= resetsAt` 或 `lastAttemptAt >= resetsAt`，说明重置后已经取过（可能服务端还未翻页仍返回旧 `resetsAt`），抑制重复击穿，并在日志里标注 `suppressedResetWindowID`。
    static func evaluate(
        _ record: DiskRecord?,
        maxAge: TimeInterval,
        now: Date = Date()
    ) -> FreshnessEvaluation {
        guard maxAge > 0 else {
            return .stale(reason: "force_refresh(maxAge=0)")
        }
        guard let record, let storedAt = record.storedAt, record.hasSnapshot else {
            return .stale(reason: "missing")
        }
        if record.provider == .antigravity,
           record.source == "antigravity.offline" || record.windows.isEmpty
        {
            return .stale(reason: "empty_antigravity_snapshot")
        }
        let age = max(0, now.timeIntervalSince(storedAt))
        guard age < maxAge else {
            return .stale(reason: String(format: "expired(age=%.1fs>=maxAge=%.1fs)", age, maxAge))
        }

        var suppressedID: String?
        let lastAttempt = record.lastAttemptAt ?? storedAt
        for w in record.windows {
            guard let resetsAt = w.resetsAt, resetsAt <= now else { continue }
            if storedAt < resetsAt && lastAttempt < resetsAt {
                return .stale(reason: "window_reset(\(w.id))")
            } else if suppressedID == nil {
                suppressedID = w.id
            }
        }
        return .fresh(age: age, suppressedResetWindowID: suppressedID)
    }

    // MARK: - 跨进程文件锁 (flock + O_CLOEXEC)

    final class FileLock: @unchecked Sendable {
        let provider: AIProvider
        let fd: Int32
        let acquiredAt: Date
        let waitedMs: Int
        let immediate: Bool
        private var released = false

        init(provider: AIProvider, fd: Int32, acquiredAt: Date, waitedMs: Int, immediate: Bool) {
            self.provider = provider
            self.fd = fd
            self.acquiredAt = acquiredAt
            self.waitedMs = waitedMs
            self.immediate = immediate
        }

        func unlock(baseDirectory: URL? = nil) {
            guard !self.released else { return }
            self.released = true
            let heldMs = Int(Date().timeIntervalSince(self.acquiredAt) * 1000)
            _ = flock(self.fd, LOCK_UN)
            _ = close(self.fd)
            UsageLogger.log(
                self.provider,
                event: "LOCK_RELEASE",
                fields: [("heldMs", "\(heldMs)")],
                baseDirectory: baseDirectory
            )
        }

        deinit {
            if !self.released {
                _ = flock(self.fd, LOCK_UN)
                _ = close(self.fd)
            }
        }
    }

    /// 异步获取 `<provider>.lock` 的排他锁，绝不阻塞协作线程池。
    /// - Returns: 成功返回 `FileLock`，超时或无法打开返回 `nil`。
    static func acquireLock(
        for provider: AIProvider,
        timeout: TimeInterval,
        baseDirectory: URL? = nil
    ) async -> FileLock? {
        let lockURL = Self.lockFileURL(for: provider, baseDirectory: baseDirectory)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            UsageLogger.log(
                provider,
                event: "LOCK_OPEN_ERROR",
                fields: [("errno", "\(errno)")],
                baseDirectory: baseDirectory
            )
            return nil
        }
        _ = fchmod(fd, 0o600)

        let start = Date()
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            UsageLogger.log(
                provider,
                event: "LOCK_ACQUIRED",
                fields: [("mode", "immediate"), ("waitMs", "0")],
                baseDirectory: baseDirectory
            )
            return FileLock(provider: provider, fd: fd, acquiredAt: Date(), waitedMs: 0, immediate: true)
        }

        let firstErr = errno
        guard firstErr == EWOULDBLOCK || firstErr == EAGAIN else {
            _ = close(fd)
            UsageLogger.log(
                provider,
                event: "LOCK_ERROR",
                fields: [("errno", "\(firstErr)")],
                baseDirectory: baseDirectory
            )
            return nil
        }

        UsageLogger.log(
            provider,
            event: "LOCK_WAIT",
            fields: [("reason", "peer_holding_lock")],
            baseDirectory: baseDirectory
        )

        let deadline = start.addingTimeInterval(max(1, timeout))
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                let now = Date()
                let waitedMs = Int(now.timeIntervalSince(start) * 1000)
                UsageLogger.log(
                    provider,
                    event: "LOCK_ACQUIRED",
                    fields: [("mode", "after_wait"), ("waitMs", "\(waitedMs)")],
                    baseDirectory: baseDirectory
                )
                return FileLock(provider: provider, fd: fd, acquiredAt: now, waitedMs: waitedMs, immediate: false)
            }
        }

        let waitedMs = Int(Date().timeIntervalSince(start) * 1000)
        _ = close(fd)
        UsageLogger.log(
            provider,
            event: "LOCK_TIMEOUT",
            fields: [("waitMs", "\(waitedMs)")],
            baseDirectory: baseDirectory
        )
        return nil
    }

    // MARK: - 跨进程通知广播

    static func postUpdateNotification(for provider: AIProvider, baseDirectory: URL? = nil) {
        // 自定义测试目录时不广播全局系统通知，避免污染宿主机正在运行的正式 App。
        guard baseDirectory == nil else { return }
        UsageLogger.log(
            provider,
            event: "NOTIFY_POST",
            fields: [("object", provider.rawValue)],
            baseDirectory: baseDirectory
        )
        DistributedNotificationCenter.default().postNotificationName(
            Self.didUpdateNotification,
            object: provider.rawValue,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    // MARK: - Antigravity 本地状态行快路与闲置「零启动」门控

    enum StatusLineEvaluation: Sendable {
        case hit(usage: ProviderUsage, trigger: String, fileAge: TimeInterval)
        case miss(reason: String)
    }

    enum IdleGateEvaluation: Sendable {
        case reuse(
            usage: ProviderUsage,
            cacheAge: TimeInterval,
            summaryDbMtimeDelta: TimeInterval?,
            latestSummaryFile: String?,
            nextResetIn: TimeInterval?
        )
        case bypass(reason: String)
    }

    /// 第 1 层快路评估：读取 `/tmp/agy_statusline_input.json` 并产出详细命中/未命中原因供可观测性日志统计。
    static func evaluateAntigravityStatusLine(
        maxAge: TimeInterval = 120,
        cachedStoredAt: Date? = nil,
        fileURL: URL = defaultAntigravityStatusLineURL,
        now: Date = Date()
    ) -> StatusLineEvaluation {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let mtime = attrs[.modificationDate] as? Date
        else {
            return .miss(reason: "file_missing")
        }

        let fileAge = max(0, now.timeIntervalSince(mtime))
        let freshnessWindow = max(maxAge, 300)
        let withinWindow = now.timeIntervalSince(mtime) <= freshnessWindow
        let newerThanCache = cachedStoredAt.map { mtime > $0 } ?? false
        guard withinWindow || newerThanCache else {
            return .miss(reason: String(format: "stale(fileAge=%.1fs>%.0fs)", fileAge, freshnessWindow))
        }
        guard let data = try? Data(contentsOf: fileURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quota = parsed["quota"] as? [String: Any]
        else {
            return .miss(reason: "invalid_json")
        }

        let rawPlan = (parsed["plan_tier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = (rawPlan?.isEmpty == false) ? rawPlan : nil

        let definitions: [(key: String, id: String, title: String, group: String, kind: UsageWindow.Kind, seconds: TimeInterval)] = [
            ("gemini-5h", "antigravity.gemini-5h", "Gemini 5-hour", "Gemini", .session, 5 * 3600),
            ("gemini-weekly", "antigravity.gemini-weekly", "Gemini weekly", "Gemini", .weekly, 7 * 86400),
            ("3p-5h", "antigravity.3p-5h", "Claude/GPT 5-hour", "Claude/GPT", .session, 5 * 3600),
            ("3p-weekly", "antigravity.3p-weekly", "Claude/GPT weekly", "Claude/GPT", .weekly, 7 * 86400),
            ("gemini-argon-wtu-weekly", "antigravity.argon-weekly", "Gemini 4 Argon weekly", "Gemini 4 Argon", .weekly, 7 * 86400),
        ]

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        var windows: [UsageWindow] = []
        for def in definitions {
            guard let obj = quota[def.key] as? [String: Any] else { continue }
            let rem = (obj["remaining_fraction"] as? NSNumber)?.doubleValue
                ?? (obj["remainingFraction"] as? NSNumber)?.doubleValue
            guard let remaining = rem, remaining.isFinite, remaining >= 0, remaining <= 1.5 else {
                return .miss(reason: "invalid_fraction(\(def.id))")
            }
            let used = max(0, ((1.0 - min(1.0, remaining)) * 100.0).rounded())
            let resetStr = (obj["reset_time"] as? String) ?? (obj["resetTime"] as? String)
            let resetDate = resetStr.flatMap { isoFrac.date(from: $0) ?? isoPlain.date(from: $0) }
            // 只要状态行中存在的任一桶缺少合法重置时间或已跨过重置时间，整份状态行视为跨周期陈旧快照，拒绝采用。
            guard let resetDate, resetDate > now else {
                return .miss(reason: "reset_passed(\(def.id))")
            }
            windows.append(UsageWindow(
                id: def.id,
                title: def.title,
                group: def.group,
                kind: def.kind,
                usedPercent: used,
                resetsAt: resetDate,
                windowSeconds: def.seconds
            ))
        }
        // 至少要有基础的 4 个窗口（Gemini + 3P）才算有效快照。
        guard windows.count >= 4 else {
            return .miss(reason: "insufficient_buckets(\(windows.count))")
        }
        let trigger = withinWindow ? "fresh" : "newer_than_cache"
        let usage = ProviderUsage(
            provider: .antigravity,
            plan: plan,
            accountEmail: nil,
            windows: windows,
            fetchedAt: mtime,
            source: "antigravity.statusline-file"
        )
        return .hit(usage: usage, trigger: trigger, fileAge: fileAge)
    }

    static func readFreshAntigravityStatusLine(
        maxAge: TimeInterval = 120,
        cachedStoredAt: Date? = nil,
        fileURL: URL = defaultAntigravityStatusLineURL,
        now: Date = Date()
    ) -> ProviderUsage? {
        if case let .hit(usage, _, _) = Self.evaluateAntigravityStatusLine(
            maxAge: maxAge,
            cachedStoredAt: cachedStoredAt,
            fileURL: fileURL,
            now: now
        ) {
            return usage
        }
        return nil
    }

    /// 第 2 层门控：检查多个汇总数据库文件的最新修改时间及对应文件名（仅取文件名，不带敏感路径）。
    static func latestModification(of urls: [URL]) -> (fileName: String, mtime: Date)? {
        var latest: (fileName: String, mtime: Date)?
        for url in urls {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date
            else { continue }
            if let current = latest {
                if mtime > current.mtime {
                    latest = (url.lastPathComponent, mtime)
                }
            } else {
                latest = (url.lastPathComponent, mtime)
            }
        }
        return latest
    }

    static func latestModificationDate(of urls: [URL]) -> Date? {
        Self.latestModification(of: urls)?.mtime
    }

    /// 第 2 层闲置「零启动」门控评估，产出详细复用指标或穿透原因（供 `IDLE_REUSE` / `LIVE_SPAWN_REASON` 打点）。
    static func evaluateIdleAntigravityCache(
        _ record: DiskRecord?,
        maxAge: TimeInterval,
        activityURLs: [URL] = defaultAntigravityActivityURLs,
        now: Date = Date()
    ) -> IdleGateEvaluation {
        guard maxAge > 0 else {
            return .bypass(reason: "force_refresh(maxAge=0)")
        }
        guard let record,
              record.provider == .antigravity,
              let storedAt = record.storedAt,
              let usage = record.toProviderUsage()
        else {
            return .bypass(reason: "no_cache")
        }
        guard record.source != "antigravity.offline", !usage.windows.isEmpty else {
            return .bypass(reason: "empty_cache")
        }

        // 条件 A：所有非 nil 的 window.resetsAt > now
        var nextResetIn: TimeInterval?
        for window in usage.windows {
            guard let resetsAt = window.resetsAt else { continue }
            if resetsAt <= now {
                return .bypass(reason: "reset_passed(window=\(window.id))")
            }
            let remaining = resetsAt.timeIntervalSince(now)
            if let currentMin = nextResetIn {
                if remaining < currentMin { nextResetIn = remaining }
            } else {
                nextResetIn = remaining
            }
        }

        // 条件 B：距上次真实采样未满 60 分钟兜底上限
        let cacheAge = max(0, now.timeIntervalSince(storedAt))
        guard cacheAge < Self.antigravityIdleCeilingSeconds else {
            return .bypass(reason: String(format: "idle_ceiling_60m(cacheAge=%.0fs)", cacheAge))
        }

        // 条件 C：汇总文件均不存在，或未晚于 storedAt + 3.0s
        let latestActivity = Self.latestModification(of: activityURLs)
        let summaryDelta = latestActivity.map { $0.mtime.timeIntervalSince(storedAt) }
        if let latestActivity,
           let delta = summaryDelta,
           latestActivity.mtime > storedAt.addingTimeInterval(Self.antigravityActivityGraceSeconds)
        {
            return .bypass(
                reason: String(format: "activity_detected(file=%@,delta=%+.1fs)", latestActivity.fileName, delta)
            )
        }

        return .reuse(
            usage: usage,
            cacheAge: cacheAge,
            summaryDbMtimeDelta: summaryDelta,
            latestSummaryFile: latestActivity?.fileName,
            nextResetIn: nextResetIn
        )
    }

    static func reusableIdleAntigravitySnapshot(
        _ record: DiskRecord?,
        maxAge: TimeInterval,
        activityURLs: [URL] = defaultAntigravityActivityURLs,
        now: Date = Date()
    ) -> ProviderUsage? {
        if case let .reuse(usage, _, _, _, _) = Self.evaluateIdleAntigravityCache(
            record,
            maxAge: maxAge,
            activityURLs: activityURLs,
            now: now
        ) {
            return usage
        }
        return nil
    }
}
