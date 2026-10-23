import Darwin
import Foundation

/// 跨进程追加写日志（`~/Library/Caches/AIUsageKit/logs/usage.log`）。
///
/// 设计约束：
/// 1. **零敏感信息**：只记时间戳、`进程名:PID`、`provider`、事件名与纯数值/标识符键值对；绝不写邮箱、token、路径或原始错误正文。
/// 2. **多进程并发安全**：每条日志独立 `open(O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)` → 单次 `write` 整行 → `close`，
///    这样即使另一个进程刚刚轮转了 `usage.log`，也不会继续往旧 inode（`usage.log.1`）里写。
/// 3. **安全轮转**：超过 2MB 时，通过 `rotate.lock`（`flock(LOCK_EX | LOCK_NB)`）互斥执行 `rename`，避免多进程同时覆盖备份。
public enum UsageLogger {
    private static let maxLogBytes: off_t = 2 * 1024 * 1024

    /// 默认日志文件路径：`~/Library/Caches/AIUsageKit/logs/usage.log`。
    public static var defaultLogFileURL: URL {
        SharedCache.defaultBaseDirectoryURL
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("usage.log", isDirectory: false)
    }

    static var processTag: String {
        let name = ProcessInfo.processInfo.processName
        return "\(name):\(getpid())"
    }

    /// 记录一条结构化事件日志。
    static func log(
        _ provider: AIProvider,
        event: String,
        fields: [(String, String)] = [],
        baseDirectory: URL? = nil
    ) {
        let root = baseDirectory ?? SharedCache.defaultBaseDirectoryURL
        let logsDir = root.appendingPathComponent("logs", isDirectory: true)
        Self.ensureDirectory(logsDir)

        let logURL = logsDir.appendingPathComponent("usage.log", isDirectory: false)
        Self.rotateIfNeeded(logURL: logURL, logsDir: logsDir)

        let ts = Self.isoTimestamp(Date())
        let kv = fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        let suffix = kv.isEmpty ? "" : " \(kv)"
        var line = "\(ts) [\(Self.processTag)] [\(provider.rawValue)] \(event)\(suffix)\n"

        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        _ = fchmod(fd, 0o600)
        line.withUTF8 { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            _ = Darwin.write(fd, base, buffer.count)
        }
        _ = close(fd)
    }

    /// 供 `UsageWindow` 列表生成紧凑摘要，例如 `[claude.session=14%,claude.weekly=32%]`。
    static func windowsSummary(_ windows: [UsageWindow]) -> String {
        let items = windows.map { w -> String in
            let pct = w.usedPercent.map { "\(Int($0.rounded()))%" } ?? "nil"
            return "\(w.id)=\(pct)"
        }
        return "[\(items.joined(separator: ","))]"
    }

    static func ensureDirectory(_ url: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return
        }
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(url.path, 0o700)
    }

    private static func rotateIfNeeded(logURL: URL, logsDir: URL) {
        var st = stat()
        guard stat(logURL.path, &st) == 0, st.st_size >= Self.maxLogBytes else { return }

        let lockURL = logsDir.appendingPathComponent("rotate.lock", isDirectory: false)
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { return }
        _ = fchmod(lockFD, 0o600)
        defer {
            _ = flock(lockFD, LOCK_UN)
            _ = close(lockFD)
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return }

        // 拿到轮转锁后再次复核大小，防止已经被别的进程轮转过了。
        var stAfter = stat()
        guard stat(logURL.path, &stAfter) == 0, stAfter.st_size >= Self.maxLogBytes else { return }
        let backupURL = logsDir.appendingPathComponent("usage.log.1", isDirectory: false)
        _ = rename(logURL.path, backupURL.path)
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
