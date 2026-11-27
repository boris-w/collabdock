import Foundation
import Testing
@testable import CollabDockCore

/// 审查执行编排服务（只剩 Lody）：准备 Lody 工作区 → 派发 Lody 会话 → 记账 → 持久化。
/// CollabDock 不再自己往 GitHub 写任何东西，也没有交付 / 会诊环节。
@Suite("ReviewExecutionService — prepare → dispatch to Lody → record usage → persist")
struct ReviewExecutionServiceTests {
    private let usage = AgentUsageMetrics(inputTokens: 1200, outputTokens: 300)

    private func lodyHandle(_ id: String) -> AgentSessionHandle {
        AgentSessionHandle(engine: .lody, sessionID: id, workspacePath: "/tmp/collabdock-fake-worktree", launchMode: .nativeBackgroundSession)
    }

    private func dispatched(_ id: String, usage: AgentUsageMetrics? = nil) -> AgentRunResult {
        AgentRunResult(output: nil, sessionHandle: lodyHandle(id), rawOutputText: "", wasBackgroundDispatched: true, usage: usage)
    }

    private struct Harness {
        let lody = FakeBackend(context: Fixtures.workspace(path: "/tmp/collabdock-lody-worktree"))
        let store = InMemoryTaskStore()
        var service: ReviewExecutionService { ReviewExecutionService(backend: lody, store: store) }
    }

    private func request(
        _ item: CollaborationItem,
        plan: ExecutionPlan,
        ticket: ExecutionRunTicket = ExecutionRunTicket(itemID: "unused")
    ) -> ReviewExecutionRequest {
        ReviewExecutionRequest(
            item: item,
            plan: plan,
            preset: TaskPreset.defaults[0],
            ticket: ticket,
            searchRoots: ["~/code"],
            preferredLocalPath: "/Users/dev/code/api",
            lodyAgentDisplayName: "Claude Code"
        )
    }

    private func lodyPlan(
        continuity: ReviewContinuityMode = .freshSessionFull,
        previous: PreviousReviewContext? = nil
    ) -> ExecutionPlan {
        ExecutionPlan(
            engine: .lody, model: "default", launchMode: .nativeBackgroundSession,
            continuityMode: continuity, previousReview: previous
        )
    }

    @Test("The service has exactly one backend, and it is Lody")
    func onlyLodyBackend() {
        let h = Harness()
        #expect(h.service.backend.kind == .lody)
    }

    @Test("First review: prepares the Lody workspace, dispatches on the run's primary token, records usage, persists a tracked item")
    func firstReviewDispatch() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        let ticket = ExecutionRunTicket(itemID: item.id)
        h.lody.result = dispatched("lody-1", usage: usage)
        let progress = ProgressRecorder()

        let outcome = try await h.service.execute(request(item, plan: lodyPlan(), ticket: ticket), onProgress: progress.record)

        guard case .backgroundDispatched(let tracked, let handle, let continued, let usageRuns) = outcome else {
            Issue.record("expected .backgroundDispatched, got \(outcome)"); return
        }
        // 准备上下文
        let prep = try #require(h.lody.prepareRequests.first)
        #expect(h.lody.prepareRequests.count == 1)
        #expect(prep.preferredLocalPath == "/Users/dev/code/api")
        #expect(prep.searchRoots == ["~/code"])
        // 派发
        let exec = try #require(h.lody.executeRequests.first)
        #expect(h.lody.executeRequests.count == 1)
        #expect(exec.workspace == Fixtures.workspace(path: "/tmp/collabdock-lody-worktree"))
        #expect(exec.cancellationToken === ticket.primary)
        #expect(exec.plan.engine == .lody)
        #expect(exec.plan.launchMode == .nativeBackgroundSession)
        // 结果：会话被跟踪，不是终态
        #expect(handle?.sessionID == "lody-1")
        #expect(continued == false)
        #expect(tracked.status == .draftReady)
        #expect(tracked.remoteSessionStatus == .running)
        #expect(tracked.sessionID == "lody-1")
        #expect(tracked.sessionHandle?.engine == .lody)
        #expect(tracked.errorMessage == nil)
        #expect(await h.store.item(item.id)?.status == .draftReady)
        // 用量
        let run = try #require(usageRuns.first)
        #expect(usageRuns.count == 1)
        #expect(run.engine == .lody)
        #expect(run.lodyAgentName == "Claude Code")
        #expect(run.sessionID == "lody-1")
        #expect(await h.store.usageRuns.count == 1)
        // 进度：全部带本次 runID，从准备推进到运行
        let events = progress.events
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.runID == ticket.runID && $0.itemID == item.id })
        #expect(events.first?.status == .preparing)
        #expect(events.contains { $0.status == .running })
    }

    @Test("Re-review continues the previous Lody session and reports it")
    func continuesPreviousLodySession() async throws {
        let h = Harness()
        let previous = PreviousReviewContext(
            previousItemID: "old", reviewedHeadSHA: "1111111", reviewedAt: Date(), engine: .lody, sessionID: "lody-1", reviewRound: 1
        )
        var item = Fixtures.prItem(status: .pendingConfirmation)
        item.previousReview = previous
        item.reviewRound = 2
        h.lody.result = dispatched("lody-1")

        let outcome = try await h.service.execute(request(item, plan: lodyPlan(continuity: .continueSessionIncremental, previous: previous)))

        guard case .backgroundDispatched(let tracked, let handle, let continued, _) = outcome else {
            Issue.record("expected .backgroundDispatched, got \(outcome)"); return
        }
        let exec = try #require(h.lody.executeRequests.first)
        #expect(exec.plan.continuityMode == .continueSessionIncremental)
        #expect(exec.plan.previousReview?.sessionID == "lody-1")
        #expect(handle?.sessionID == "lody-1")
        #expect(continued)
        #expect(tracked.remoteSessionStatus == .running)
        #expect(await h.store.item(item.id)?.sessionID == "lody-1")
    }

    // MARK: cancellation

    @Test("Cancelled while preparing: nothing is dispatched and nothing is marked failed")
    func cancelledDuringPrepare() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        let ticket = ExecutionRunTicket(itemID: item.id)
        h.lody.onPrepare = { ticket.cancel() }
        h.lody.result = dispatched("lody-1")

        let outcome = try await h.service.execute(request(item, plan: lodyPlan(), ticket: ticket))

        guard case .cancelled(let itemID, let runID) = outcome else { Issue.record("expected .cancelled, got \(outcome)"); return }
        #expect(itemID == item.id)
        #expect(runID == ticket.runID)
        #expect(h.lody.executeRequests.isEmpty)
        #expect(await h.store.item(item.id)?.status != .failed)
    }

    @Test("Cancelled while dispatching: the result is discarded and nothing is marked failed")
    func cancelledDuringExecute() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        let ticket = ExecutionRunTicket(itemID: item.id)
        h.lody.onExecute = { _ in ticket.cancel() }
        h.lody.result = dispatched("lody-1", usage: usage)

        let outcome = try await h.service.execute(request(item, plan: lodyPlan(), ticket: ticket))

        guard case .cancelled = outcome else { Issue.record("expected .cancelled, got \(outcome)"); return }
        #expect(await h.store.item(item.id)?.status != .failed)
        #expect(await h.store.item(item.id)?.sessionID == nil)
    }

    // MARK: failures

    @Test("Lody failure: the error is thrown and the item is persisted as failed with the message")
    func lodyFailureMarksItemFailed() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        h.lody.executeError = AgentRunnerError.processFailed(exitCode: 1, stderr: "Workspace quota exceeded")

        await #expect(throws: AgentRunnerError.self) {
            _ = try await h.service.execute(request(item, plan: lodyPlan()))
        }
        let stored = await h.store.item(item.id)
        #expect(stored?.status == .failed)
        #expect(stored?.errorMessage?.contains("Workspace quota exceeded") == true)
    }

    @Test("Workspace preparation failure: the error is thrown and the item is persisted as failed")
    func prepareFailureMarksItemFailed() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        h.lody.prepareError = WorkspaceError.fetchFailed("repository not found")

        await #expect(throws: WorkspaceError.self) {
            _ = try await h.service.execute(request(item, plan: lodyPlan()))
        }
        #expect(h.lody.executeRequests.isEmpty)
        #expect(await h.store.item(item.id)?.status == .failed)
    }

    @Test(
        "Store failures surface as PersistenceError instead of being swallowed",
        arguments: [PersistenceOperation.upsertUsageRun, .upsertItem]
    )
    func storeFailuresAreReported(operation: PersistenceOperation) async throws {
        let h = Harness()
        await h.store.fail(operation)
        let item = Fixtures.prItem(status: .pendingConfirmation)
        h.lody.result = dispatched("lody-1", usage: usage)

        do {
            _ = try await h.service.execute(request(item, plan: lodyPlan()))
            Issue.record("expected PersistenceError(\(operation))")
        } catch let error as PersistenceError {
            #expect(error.operation == operation)
        }
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ReviewExecutionProgress] = []
    var events: [ReviewExecutionProgress] { lock.withLock { recorded } }
    var record: @Sendable (ReviewExecutionProgress) -> Void {
        { [weak self] event in self?.lock.withLock { self?.recorded.append(event) } }
    }
}
