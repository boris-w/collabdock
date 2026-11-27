import Foundation
@testable import CollabDockApp
@testable import CollabDockCore

// App 层测试用的假依赖。刻意不与 CollabDockCoreTests 共享，避免跨测试 target 的耦合。

// MARK: - Settings / environment / system

final class InMemorySettingsStore: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var current: AppSettings
    private var saves: [AppSettings] = []

    init(_ settings: AppSettings = AppSettings()) { current = settings }

    var savedSettings: [AppSettings] { lock.withLock { saves } }

    func load() -> AppSettings { lock.withLock { current } }
    func save(_ settings: AppSettings) throws { lock.withLock { current = settings; saves.append(settings) } }
    func exportTeamPresetData(teamName: String, from settings: AppSettings) throws -> Data { Data() }
    func decodeTeamPreset(from data: Data) throws -> TeamPreset { try JSONDecoder().decode(TeamPreset.self, from: data) }
    func loadLodyCatalogCache() -> LodyCatalogSnapshot? { nil }
    func saveLodyCatalogCache(_ snapshot: LodyCatalogSnapshot) {}
}

struct StaticEnvironment: EnvironmentDetecting {
    var snapshot = EnvironmentSnapshot(
        resolvedPATH: "/usr/bin:/bin",
        git: CLIProbeStatus(name: "git", isInstalled: true, executablePath: "/usr/bin/git"),
        gh: CLIProbeStatus(name: "gh", isInstalled: true, executablePath: "/usr/local/bin/gh"),
        engines: [
            .claudeCode: CLIProbeStatus(name: "claude", isInstalled: true, executablePath: "/usr/local/bin/claude"),
            .codex: CLIProbeStatus(name: "codex", isInstalled: true, executablePath: "/usr/local/bin/codex")
        ],
        githubAuth: GitHubAuthSnapshot(isAuthenticated: true, username: "me", tokenSource: .ghCLI, hasNotificationsScope: true),
        discoveredModels: [:]
    )

    func detectAll(customPaths: [String: String], manualGitHubPAT: String?) async -> EnvironmentSnapshot { snapshot }
    func resolveGitHubToken(ghExecutablePath: String?, manualPAT: String?) async -> String? { "gho_placeholder" }
    func fetchLodyCatalog(lodyProbe: CLIProbeStatus, workspace: String?, resolvedPATH: String?) async -> LodyCatalogSnapshot? { nil }
    func fetchLodySessionUsage(lodyProbe: CLIProbeStatus, sessionID: String, workspace: String?, resolvedPATH: String?) async -> EnvironmentDetector.LodySessionUsageSnapshot? { nil }
}

@MainActor
final class RecordingSystemIntegration: SystemIntegrating {
    var onNotificationSelectedItem: ((String) -> Void)?
    private(set) var configureCount = 0
    private(set) var incoming: [String] = []
    private(set) var completions: [String] = []
    private(set) var launchAtLogin: [Bool] = []

    func configureNotificationsIfAvailable() { configureCount += 1 }
    func postIncomingTaskNotification(for item: CollaborationItem, enabled: Bool) { if enabled { incoming.append(item.id) } }
    func postCompletionNotification(for item: CollaborationItem, summary: String, enabled: Bool) { if enabled { completions.append(item.id) } }
    func setLaunchAtLogin(_ enabled: Bool) -> String? { launchAtLogin.append(enabled); return nil }
    func openSessionHandoff(handle: AgentSessionHandle, lodyWorkspace: String?) {}
    func openLocalReport(path: String) {}
}

final class FixedClock: ClockProviding, @unchecked Sendable {
    let now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }
}

// MARK: - Store

actor MemoryTaskStore: TaskStore {
    struct Failure: Error, LocalizedError {
        let op: PersistenceOperation
        var errorDescription: String? { "disk full (\(op.rawValue))" }
    }

    private(set) var items: [String: CollaborationItem] = [:]
    private(set) var seen: [String: String] = [:]
    private var cursors: [PlatformKind: SyncCursor] = [:]
    private(set) var usage: [String: ReviewUsageRun] = [:]
    private var failing: Set<PersistenceOperation> = []

    init(items: [CollaborationItem] = []) { for i in items { self.items[i.id] = i } }

    func fail(_ ops: PersistenceOperation...) { failing.formUnion(ops) }
    private func check(_ op: PersistenceOperation) throws { if failing.contains(op) { throw Failure(op: op) } }

    func loadAllItems() async throws -> [CollaborationItem] { try check(.loadAllItems); return Array(items.values) }
    func upsertItem(_ item: CollaborationItem) async throws { try check(.upsertItem); items[item.id] = item }
    func deleteItem(id: String) async throws { try check(.deleteItem); items.removeValue(forKey: id) }
    func hasSeen(dedupeKey: String) async throws -> Bool { try check(.hasSeen); return seen[dedupeKey] != nil }
    func markSeen(dedupeKey: String, itemID: String) async throws { try check(.markSeen); seen[dedupeKey] = itemID }
    func loadCursor(for platform: PlatformKind) async throws -> SyncCursor? { try check(.loadCursor); return cursors[platform] }
    func saveCursor(_ cursor: SyncCursor, for platform: PlatformKind) async throws { try check(.saveCursor); cursors[platform] = cursor }
    func loadAllUsageRuns() async throws -> [ReviewUsageRun] { try check(.loadAllUsageRuns); return Array(usage.values) }
    func upsertUsageRun(_ run: ReviewUsageRun) async throws { try check(.upsertUsageRun); usage[run.id] = run }
}

// MARK: - Connectors

final class ScriptedSource: CollaborationSource, @unchecked Sendable {
    let platform: PlatformKind = .github
    private let lock = NSLock()
    var result: Result<PollBatch, Error>
    private(set) var pollCount = 0

    init(_ result: Result<PollBatch, Error> = .success(PollBatch(candidates: []))) { self.result = result }

    func poll(_ request: PollRequest) async throws -> PollBatch {
        let r = lock.withLock { pollCount += 1; return result }
        return try r.get()
    }
}

final class ScriptedStatusQuery: PRStatusQuerying, @unchecked Sendable {
    let platform: PlatformKind = .github
    var result = PRStatusBatchResult()
    func fetchPRStatusSnapshots(targets: [PRStateReconciler.Target]) async throws -> PRStatusBatchResult { result }
}

struct ScriptedFetcher: PullRequestFetching {
    let platform: PlatformKind = .github
    var item: CollaborationItem?
    func fetchPullRequest(reference: String) async throws -> CollaborationItem {
        guard let item else { throw GitHubConnectorError.httpError(statusCode: 404, message: "not found") }
        return item
    }
}

final class RecordingSink: CollaborationSink, @unchecked Sendable {
    let platform: PlatformKind = .github
    private let lock = NSLock()
    private var delivered: [String] = []
    var deliveries: [String] { lock.withLock { delivered } }

    func supportedDeliveryModes(for item: CollaborationItem) -> [DeliveryMode] { ConnectorCatalog.supportedDeliveryModes(for: item) }
    func deliver(output: ExecutionOutput, for item: CollaborationItem, mode: DeliveryMode, context: DeliveryContext) async throws -> DeliveryReceipt {
        lock.withLock { delivered.append(item.id) }
        return DeliveryReceipt(deliveredMode: mode, destinationURL: item.url, localReportPath: URL(fileURLWithPath: "/tmp/collabdock-app-test-report.md"))
    }
}

struct FakeConnectorFactory: ConnectorFactory {
    var source: ScriptedSource = ScriptedSource()
    var status = ScriptedStatusQuery()
    var fetcher = ScriptedFetcher()
    var sink = RecordingSink()

    func makeSource(context: ConnectorBuildContext) -> (any CollaborationSource)? { source }
    func makePRStatusQuery(context: ConnectorBuildContext) -> (any PRStatusQuerying)? { status }
    func makePRFetcher(context: ConnectorBuildContext) -> (any PullRequestFetching)? { fetcher }
    func makeSink(context: ConnectorBuildContext) -> (any CollaborationSink)? { sink }
}

// MARK: - Execution backend

/// 可脚本化的执行后端：`blockUntilCancelled` 时模拟一个一直在跑、直到用户中止的 AI 进程
final class ScriptedBackend: ExecutionBackend, @unchecked Sendable {
    let kind: ExecutionBackendKind
    let supportedEngines: [AgentEngine]
    private let lock = NSLock()
    private var _blockUntilCancelled = false
    private var _lingerAfterCancelSeconds: Double = 0
    private var _result: Result<AgentRunResult, Error> = .success(
        AgentRunResult(
            output: .codeReview(CodeReviewResult(summary: "Looks good.", recommendedVerdict: .comment, comments: [])),
            sessionHandle: nil,
            rawOutputText: "",
            usage: AgentUsageMetrics(inputTokens: 100, outputTokens: 20)
        )
    )
    private(set) var executeCount = 0

    init(kind: ExecutionBackendKind = .directCLI, engines: [AgentEngine] = [.claudeCode, .codex, .antigravity]) {
        self.kind = kind
        self.supportedEngines = engines
    }

    var blockUntilCancelled: Bool {
        get { lock.withLock { _blockUntilCancelled } }
        set { lock.withLock { _blockUntilCancelled = newValue } }
    }
    /// 被中止后再拖一会儿才退出（真实进程被 kill 后也需要时间退出），用来让「旧运行的收尾」确定地晚于新运行
    var lingerAfterCancelSeconds: Double {
        get { lock.withLock { _lingerAfterCancelSeconds } }
        set { lock.withLock { _lingerAfterCancelSeconds = newValue } }
    }
    var result: Result<AgentRunResult, Error> {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    func prepareWorkspace(for request: WorkspacePreparationRequest, onProgress: @escaping @Sendable (String) -> Void) async throws -> PreparedWorkspaceContext {
        PreparedWorkspaceContext(workspaceURL: URL(fileURLWithPath: "/tmp/collabdock-app-test-wt", isDirectory: true), unifiedDiff: "diff")
    }

    func buildCommand(for request: AgentRunRequest, prompt: String, schemaFileURL: URL, outputFileURL: URL?) throws -> AgentCommandSpec {
        AgentCommandSpec(executable: "/usr/bin/true", arguments: [], workingDirectory: request.workspace.workspaceURL)
    }

    func execute(_ request: AgentRunRequest, onProgress: @escaping @Sendable (String) -> Void) async throws -> AgentRunResult {
        let (block, scripted) = lock.withLock { () -> (Bool, Result<AgentRunResult, Error>) in
            executeCount += 1
            return (_blockUntilCancelled, _result)
        }
        onProgress("running")
        if block {
            while !request.cancellationToken.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let linger = lingerAfterCancelSeconds
            if linger > 0 { try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000)) }
            throw AgentRunnerError.cancelled
        }
        return try scripted.get()
    }

    func parseResult(_ raw: RawExecutionOutput, for request: AgentRunRequest) throws -> AgentRunResult {
        AgentRunResult(output: nil, sessionHandle: nil, rawOutputText: raw.stdout)
    }
    func makeSessionHandle(sessionID: String?, for request: AgentRunRequest) -> AgentSessionHandle? { nil }
    func resumeShellCommand(for handle: AgentSessionHandle) -> String { "" }
}

/// 每次 makeDirectBackend 依次返回队列中的后端（用于「取消后立刻重跑」这类需要两个不同后端行为的场景）
final class QueueBackendFactory: ExecutionBackendFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ScriptedBackend]
    private let fallback: ScriptedBackend

    init(_ backends: [ScriptedBackend]) {
        queue = backends
        fallback = backends.last ?? ScriptedBackend()
    }

    func makeDirectBackend() -> any ExecutionBackend {
        lock.withLock { queue.isEmpty ? fallback : queue.removeFirst() }
    }

    func makeLodyBackend(config: LodyConfig, catalog: LodyCatalogSnapshot?) -> any ExecutionBackend {
        ScriptedBackend(kind: .lody, engines: [.lody])
    }
}

// MARK: - Builders & helpers

enum AppFixtures {
    static func prItem(number: Int = 7, sha: String = "abc1234", status: CollaborationTaskStatus = .pendingConfirmation) -> CollaborationItem {
        CollaborationItem(
            id: "github:acme/backend#\(number):reviewRequested:\(sha)",
            platform: .github,
            itemKind: .pullRequest,
            scope: "acme/backend",
            externalRef: "#\(number)",
            title: "PR \(number)",
            url: URL(string: "https://github.com/acme/backend/pull/\(number)")!,
            author: "alice",
            triggeredBy: "alice",
            triggerKind: .reviewRequested,
            payload: .codeChange(CodeChangePayload(
                repository: "acme/backend", number: number, baseRef: "main", headRef: "feat/\(number)",
                headSHA: sha, additions: 1, deletions: 0, changedFiles: 1
            )),
            status: status
        )
    }

    static func candidate(number: Int = 7, sha: String = "abc1234") -> PolledCollaborationCandidate {
        let item = prItem(number: number, sha: sha)
        return PolledCollaborationCandidate(
            dedupeKey: "github:acme/backend#\(number):reviewRequested:\(sha)",
            event: IncomingCollaborationEvent(platform: .github, scope: "acme/backend", externalRef: "#\(number)", triggerKind: .reviewRequested, actor: "alice"),
            item: item
        )
    }
}

/// 轮询等待异步副作用（App 层有些持久化是 fire-and-forget 的 Task）
@MainActor
func eventually(timeout: TimeInterval = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
