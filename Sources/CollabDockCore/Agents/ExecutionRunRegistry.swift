import Foundation

/// 单次 AI 执行任务的独立身份凭据（带唯一 `runID` 及主/双引擎会诊双取消令牌，避免中止重跑竞态）
public struct ExecutionRunTicket: Sendable {
    public let itemID: String
    public let runID: UUID
    public let primary: ProcessCancellationToken
    public let secondary: ProcessCancellationToken

    public init(
        itemID: String,
        runID: UUID = UUID(),
        primary: ProcessCancellationToken = ProcessCancellationToken(),
        secondary: ProcessCancellationToken = ProcessCancellationToken()
    ) {
        self.itemID = itemID
        self.runID = runID
        self.primary = primary
        self.secondary = secondary
    }

    public var isCancelled: Bool {
        primary.isCancelled || secondary.isCancelled
    }

    public func cancel() {
        primary.cancel()
        secondary.cancel()
    }
}

/// 按 `itemID` 追踪当前有效运行凭据的注册表：保证旧运行的延迟清理与回调永远不会覆盖或取消新运行
public struct ExecutionRunRegistry: Sendable {
    private var activeRuns: [String: ExecutionRunTicket] = [:]

    public init() {}

    /// 开启一条新运行；若同条目已有在途运行，会先取消旧运行再登记新凭据
    public mutating func begin(itemID: String) -> ExecutionRunTicket {
        if let existing = activeRuns[itemID] {
            existing.cancel()
        }
        let ticket = ExecutionRunTicket(itemID: itemID)
        activeRuns[itemID] = ticket
        return ticket
    }

    /// 判断传入凭据是否仍是该条目当前的有效运行
    public func isCurrent(_ ticket: ExecutionRunTicket) -> Bool {
        activeRuns[ticket.itemID]?.runID == ticket.runID
    }

    /// 判断该条目当前是否有在途运行
    public func isRunning(itemID: String) -> Bool {
        activeRuns[itemID] != nil
    }

    /// 结束运行：仅当该凭据仍是当前有效运行时才移除，防止旧任务 defer 误删新运行
    public mutating func finish(_ ticket: ExecutionRunTicket) {
        guard isCurrent(ticket) else { return }
        activeRuns.removeValue(forKey: ticket.itemID)
    }

    /// 取消并注销该条目的当前在途运行（同时取消主/副引擎进程令牌）
    @discardableResult
    public mutating func cancel(itemID: String) -> Bool {
        guard let existing = activeRuns.removeValue(forKey: itemID) else {
            return false
        }
        existing.cancel()
        return true
    }
}
