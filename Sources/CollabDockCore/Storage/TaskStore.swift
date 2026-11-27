import Foundation

/// 持久化层操作标识，用于向调用方精确上报失败环节，严禁静默吞错
public enum PersistenceOperation: String, Codable, Equatable, Hashable, Sendable {
    case loadAllItems
    case upsertItem
    case deleteItem
    case hasSeen
    case markSeen
    case loadCursor
    case saveCursor
    case loadAllUsageRuns
    case upsertUsageRun
}

/// 持久化失败结构化错误（由 Core 服务向上抛出，确保调用方与 UI 感知并展示，而不是被 `try?` 吞掉）
public struct PersistenceError: Error, LocalizedError, Equatable, Sendable {
    public let operation: PersistenceOperation
    public let underlyingDescription: String

    public init(operation: PersistenceOperation, underlyingDescription: String) {
        self.operation = operation
        self.underlyingDescription = underlyingDescription
    }

    public init(operation: PersistenceOperation, underlying: any Error) {
        self.operation = operation
        self.underlyingDescription = underlying.localizedDescription
    }

    public var errorDescription: String? {
        CoreL10n.format("Local storage operation failed (%@): %@", operation.rawValue, underlyingDescription)
    }
}

/// 任务、游标、去重键与用量账本统一存储协议（`SQLiteTaskStore` 为生产实现，测试可注入内存/故障 Fake）
public protocol TaskStore: Sendable {
    func loadAllItems() async throws -> [CollaborationItem]
    func upsertItem(_ item: CollaborationItem) async throws
    func deleteItem(id: String) async throws
    func hasSeen(dedupeKey: String) async throws -> Bool
    func markSeen(dedupeKey: String, itemID: String) async throws
    func loadCursor(for platform: PlatformKind) async throws -> SyncCursor?
    func saveCursor(_ cursor: SyncCursor, for platform: PlatformKind) async throws
    func loadAllUsageRuns() async throws -> [ReviewUsageRun]
    func upsertUsageRun(_ run: ReviewUsageRun) async throws
}

extension SQLiteTaskStore: TaskStore {}
