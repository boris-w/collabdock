import Foundation
@testable import CollabDockCore

// MARK: - Store

/// 内存 TaskStore，可按操作注入失败，用来验证「持久化失败必须上报」
actor InMemoryTaskStore: TaskStore {
    struct InjectedFailure: Error, LocalizedError {
        let operation: PersistenceOperation
        var errorDescription: String? { "injected failure: \(operation.rawValue)" }
    }

    private(set) var items: [String: CollaborationItem] = [:]
    private(set) var seen: [String: String] = [:]
    private(set) var cursors: [PlatformKind: SyncCursor] = [:]
    private(set) var usageRuns: [String: ReviewUsageRun] = [:]
    private(set) var upsertedItemIDs: [String] = []
    private var failing: Set<PersistenceOperation> = []

    init(items: [CollaborationItem] = [], seen: [String: String] = [:]) {
        for item in items { self.items[item.id] = item }
        self.seen = seen
    }

    func fail(_ operations: PersistenceOperation...) { failing.formUnion(operations) }

    private func check(_ op: PersistenceOperation) throws {
        if failing.contains(op) { throw InjectedFailure(operation: op) }
    }

    func loadAllItems() async throws -> [CollaborationItem] { try check(.loadAllItems); return Array(items.values) }
    func upsertItem(_ item: CollaborationItem) async throws {
        try check(.upsertItem)
        items[item.id] = item
        upsertedItemIDs.append(item.id)
    }
    func deleteItem(id: String) async throws { try check(.deleteItem); items.removeValue(forKey: id) }
    func hasSeen(dedupeKey: String) async throws -> Bool { try check(.hasSeen); return seen[dedupeKey] != nil }
    func markSeen(dedupeKey: String, itemID: String) async throws { try check(.markSeen); seen[dedupeKey] = itemID }
    func loadCursor(for platform: PlatformKind) async throws -> SyncCursor? { try check(.loadCursor); return cursors[platform] }
    func saveCursor(_ cursor: SyncCursor, for platform: PlatformKind) async throws { try check(.saveCursor); cursors[platform] = cursor }
    func loadAllUsageRuns() async throws -> [ReviewUsageRun] { try check(.loadAllUsageRuns); return Array(usageRuns.values) }
    func upsertUsageRun(_ run: ReviewUsageRun) async throws { try check(.upsertUsageRun); usageRuns[run.id] = run }

    func item(_ id: String) -> CollaborationItem? { items[id] }
    func setCursor(_ cursor: SyncCursor, for platform: PlatformKind) { cursors[platform] = cursor }
}

// MARK: - Clock

final class TestClock: ClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

// MARK: - Connector fakes

/// 假的事件源：按顺序回放 batch（或抛错），并记录每次收到的 PollRequest
final class FakeSource: CollaborationSource, @unchecked Sendable {
    let platform: PlatformKind = .github
    private let lock = NSLock()
    private var script: [Result<PollBatch, Error>]
    private var requests: [PollRequest] = []

    init(_ script: [Result<PollBatch, Error>]) { self.script = script }

    var pollRequests: [PollRequest] { lock.withLock { requests } }
    var pollCount: Int { pollRequests.count }

    func poll(_ request: PollRequest) async throws -> PollBatch {
        let next: Result<PollBatch, Error> = lock.withLock {
            requests.append(request)
            return script.count > 1 ? script.removeFirst() : (script.first ?? .success(PollBatch(candidates: [])))
        }
        return try next.get()
    }
}

final class FakePRStatusQuery: PRStatusQuerying, @unchecked Sendable {
    let platform: PlatformKind = .github
    private let lock = NSLock()
    private var calls: [[PRStateReconciler.Target]] = []
    var result: PRStatusBatchResult

    init(_ result: PRStatusBatchResult = PRStatusBatchResult()) { self.result = result }

    var queriedTargets: [[PRStateReconciler.Target]] { lock.withLock { calls } }

    func fetchPRStatusSnapshots(targets: [PRStateReconciler.Target]) async throws -> PRStatusBatchResult {
        lock.withLock { calls.append(targets) }
        return result
    }
}

struct FakePRFetcher: PullRequestFetching {
    let platform: PlatformKind = .github
    let item: CollaborationItem
    func fetchPullRequest(reference: String) async throws -> CollaborationItem { item }
}

// MARK: - Backend fake

/// 假 Lody 执行后端：记录 prepare / execute 调用，按脚本返回结果；可在执行中途模拟用户中止
final class FakeBackend: ExecutionBackend, @unchecked Sendable {
    let kind: ExecutionBackendKind = .lody
    private let lock = NSLock()
    private var prepares: [WorkspacePreparationRequest] = []
    private var executes: [AgentRunRequest] = []

    var context: PreparedWorkspaceContext
    var prepareError: Error?
    var result: AgentRunResult?
    var executeError: Error?
    var onPrepare: (@Sendable () -> Void)?
    var onExecute: (@Sendable (AgentRunRequest) -> Void)?

    init(context: PreparedWorkspaceContext = Fixtures.workspace()) {
        self.context = context
    }

    var prepareRequests: [WorkspacePreparationRequest] { lock.withLock { prepares } }
    var executeRequests: [AgentRunRequest] { lock.withLock { executes } }

    func prepareWorkspace(for request: WorkspacePreparationRequest, onProgress: @escaping @Sendable (String) -> Void) async throws -> PreparedWorkspaceContext {
        lock.withLock { prepares.append(request) }
        onPrepare?()
        if let prepareError { throw prepareError }
        return context
    }

    func buildCommand(for request: AgentRunRequest, prompt: String) throws -> AgentCommandSpec {
        AgentCommandSpec(executable: "/usr/bin/true", arguments: [], workingDirectory: request.workspace.workspaceURL)
    }

    func execute(_ request: AgentRunRequest, onProgress: @escaping @Sendable (String) -> Void) async throws -> AgentRunResult {
        lock.withLock { executes.append(request) }
        onProgress("fake progress from \(request.plan.engine.rawValue)")
        onExecute?(request)
        if let executeError { throw executeError }
        guard let result else {
            throw AgentRunnerError.unparseableOutput("no scripted result")
        }
        return result
    }

    func parseResult(_ raw: RawExecutionOutput, for request: AgentRunRequest) throws -> AgentRunResult {
        AgentRunResult(output: nil, sessionHandle: nil, rawOutputText: raw.stdout)
    }

    func makeSessionHandle(sessionID: String?, for request: AgentRunRequest) -> AgentSessionHandle? { nil }

    func resumeShellCommand(for handle: AgentSessionHandle) -> String { "" }
}

// MARK: - Builders

extension Fixtures {
    static func candidate(
        repository: String = "acme/api",
        number: Int = 1,
        headSHA: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        triggerKind: TriggerKind = .reviewRequested,
        actor: String = "alice",
        body: String? = nil
    ) -> PolledCollaborationCandidate {
        let item = prItem(repository: repository, number: number, headSHA: headSHA, status: .pendingConfirmation)
        return PolledCollaborationCandidate(
            dedupeKey: "github:\(repository)#\(number):\(triggerKind.rawValue):\(headSHA)",
            event: IncomingCollaborationEvent(
                platform: .github,
                scope: repository,
                externalRef: "#\(number)",
                triggerKind: triggerKind,
                actor: actor,
                body: body
            ),
            item: item
        )
    }

    static func codeReview(_ summary: String = "Looks fine.", comments: [CodeInlineComment] = []) -> ExecutionOutput {
        .codeReview(CodeReviewResult(summary: summary, recommendedVerdict: .comment, comments: comments))
    }

    static func workspace(path: String = "/tmp/collabdock-fake-worktree") -> PreparedWorkspaceContext {
        PreparedWorkspaceContext(
            workspaceURL: URL(fileURLWithPath: path, isDirectory: true),
            isTemporaryWorktree: true
        )
    }
}
