import Darwin
import Foundation

/// 兜底清理：不信任 `claude` / `agy` / `grok` 会按时退出。
///
/// 只动**本进程直接启动的**、可执行文件名在名单里的子进程，杀掉它所在的整个进程组
/// （CodexBar 启动这些命令时会让每个子进程自成一组，所以它们派生的 `caffeinate`、MCP 服务等也一起清掉）。
/// 绝不碰本进程自己所在的进程组。
enum ChildReaper {
    /// 各家对应的可执行文件名（`proc_bsdinfo.pbi_name` / `pbi_comm`）。
    static func executableName(for provider: AIProvider) -> String {
        switch provider {
        case .claude: "claude"
        case .antigravity: "agy"
        case .grok: "grok"
        }
    }

    static let allNames: Set<String> = Set(AIProvider.allCases.map(executableName(for:)))

    struct Child: Equatable {
        let pid: pid_t
        let pgid: pid_t
        let name: String
        let startedAt: Date
    }

    /// 本进程当前的直接子进程里，名字在名单内的那些。
    static func children(named names: Set<String>) -> [Child] {
        let me = getpid()
        var pids = [pid_t](repeating: 0, count: 512)
        let count = Int(proc_listchildpids(me, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return [] }
        return pids.prefix(min(count, pids.count)).compactMap { pid in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            guard pid_t(info.pbi_ppid) == me else { return nil }
            let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let comm = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let matched = names.contains(name) ? name : names.contains(comm) ? comm : nil
            guard let matched else { return nil }
            let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
            return Child(pid: pid, pgid: pid_t(info.pbi_pgid), name: matched, startedAt: started)
        }
    }

    /// 杀掉符合条件的子进程（连同它的进程组）。先 SIGTERM，2 秒后再 SIGKILL。
    /// - Parameters:
    ///   - startedAfter: 只杀这个时间之后启动的（超时清理用：只清本次取数期间启动的）。
    ///   - olderThan: 只杀已经运行超过这么多秒的（定期兜底用）。
    /// - Returns: 被清理的子进程。
    @discardableResult
    static func reap(
        names: Set<String> = allNames,
        startedAfter: Date? = nil,
        olderThan age: TimeInterval? = nil,
        now: Date = Date()) -> [Child]
    {
        let stale = self.children(named: names).filter { child in
            if let startedAfter, child.startedAt < startedAfter.addingTimeInterval(-1) { return false }
            if let age, now.timeIntervalSince(child.startedAt) < age { return false }
            return true
        }
        guard !stale.isEmpty else { return [] }
        let ownGroup = getpgrp()
        for child in stale {
            self.signal(child, SIGTERM, ownGroup: ownGroup)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for child in stale {
                self.signal(child, SIGKILL, ownGroup: ownGroup)
            }
        }
        return stale
    }

    private static func signal(_ child: Child, _ sig: Int32, ownGroup: pid_t) {
        if child.pgid > 1, child.pgid != ownGroup {
            _ = kill(-child.pgid, sig)   // 整个进程组
        } else {
            _ = kill(child.pid, sig)     // 和我们同组时只杀它自己
        }
    }
}
