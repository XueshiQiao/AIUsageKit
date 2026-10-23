import Foundation

/// 进程内按厂商隔离的单飞协调器：
/// 1. `activeTasks`：当前进程里正在执行的协调任务（含等锁 + Double-Check + CLI）。
///    同进程内如果对同一家并发调用 `fetch`，后来者直接 `await` 同一个 `Task`，保证同进程对同一把文件锁最多只 `open` 一次。
/// 2. `runningCLI`：底层 CLI 子进程是否还在跑。如果上一次虽然超时返回了，但底层进程还没退出，则拒绝再启动新 CLI。
actor InFlight {
    static let shared = InFlight()
    private var runningCLI: Set<AIProvider> = []
    private var activeTasks: [AIProvider: Task<ProviderUsage, Error>] = [:]

    /// 同进程单飞合并：如果已有正在运行的任务，直接复用它；否则注册并执行 `operation`。
    func coalesce(
        _ provider: AIProvider,
        operation: @Sendable @escaping () async throws -> ProviderUsage
    ) async throws -> ProviderUsage {
        if let existing = self.activeTasks[provider] {
            return try await existing.value
        }
        let task = Task<ProviderUsage, Error> {
            try await operation()
        }
        self.activeTasks[provider] = task
        defer {
            self.activeTasks[provider] = nil
        }
        return try await task.value
    }

    /// 没在跑就标记为在跑并返回 true；已经在跑返回 false。
    func begin(_ provider: AIProvider) -> Bool {
        self.runningCLI.insert(provider).inserted
    }

    func end(_ provider: AIProvider) {
        self.runningCLI.remove(provider)
    }

    func isRunning(_ provider: AIProvider) -> Bool {
        self.runningCLI.contains(provider)
    }
}

/// 「谁先到用谁」：取数结果和超时谁先 finish 谁赢，后到的被忽略。等待方一定会在第一个 finish 时返回。
final class Race<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    /// - Returns: 这次 finish 是否赢了（是第一个）。
    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        self.lock.lock()
        guard self.result == nil else {
            self.lock.unlock()
            return false
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(with: result)
        return true
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            if let result = self.result {
                self.lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                self.lock.unlock()
            }
        }
    }
}
