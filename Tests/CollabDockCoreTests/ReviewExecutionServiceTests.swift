import Foundation
import Testing
@testable import CollabDockCore

/// SPEC：从 AppCoordinator.confirmAndRun 下沉到 Core 的审查执行编排服务。
@Suite("ReviewExecutionService — prepare → run (single / council / background) → deliver → persist")
struct ReviewExecutionServiceTests {
    private let usage = AgentUsageMetrics(inputTokens: 1200, outputTokens: 300)

    private func handle(_ engine: AgentEngine, _ id: String, launch: ExecutionLaunchMode = .managedStructuredRun) -> AgentSessionHandle {
        AgentSessionHandle(engine: engine, sessionID: id, workspacePath: "/tmp/collabdock-fake-worktree", launchMode: launch)
    }

    private struct Harness {
        let direct: FakeBackend
        let lody: FakeBackend
        let sink = FakeSink()
        let store = InMemoryTaskStore()
        let service: ReviewExecutionService

        init() {
            direct = FakeBackend(kind: .directCLI, engines: [.claudeCode, .codex, .antigravity], context: Fixtures.workspace(diff: "DIFF-A"))
            lody = FakeBackend(kind: .lody, engines: [.lody], context: Fixtures.workspace(diff: "DIFF-L"))
            service = ReviewExecutionService(directBackend: direct, lodyBackend: lody, sink: sink, store: store)
        }
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
            preferredLocalPath: "/Users/dev/code/api"
        )
    }

    @Test("Routes .lody to the Lody backend and every direct CLI engine to the direct backend")
    func backendRouting() {
        let h = Harness()
        #expect(h.service.backend(for: .lody).kind == .lody)
        for engine in [AgentEngine.claudeCode, .codex, .antigravity] {
            #expect(h.service.backend(for: engine).kind == .directCLI)
        }
    }

    @Test("Single engine: prepares context, runs with the run's primary token, delivers with the diff, records usage, persists the draft")
    func singleEngineHappyPath() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        let ticket = ExecutionRunTicket(itemID: item.id)
        let plan = ExecutionPlan(engine: .claudeCode, model: "sonnet", deliveryMode: .platformDraft)
        h.direct.results[.claudeCode] = AgentRunResult(
            output: Fixtures.codeReview("all good"),
            sessionHandle: handle(.claudeCode, "sess-1"),
            rawOutputText: "",
            usage: usage,
            durationSeconds: 3
        )
        let progress = ProgressRecorder()

        let outcome = try await h.service.execute(request(item, plan: plan, ticket: ticket), onProgress: progress.record)

        guard case .delivered(let delivered, let receipt, let usageRuns) = outcome else {
            Issue.record("expected .delivered, got \(outcome)"); return
        }
        // 准备上下文
        let prep = try #require(h.direct.prepareRequests.first)
        #expect(h.direct.prepareRequests.count == 1)
        #expect(prep.preferredLocalPath == "/Users/dev/code/api")
        #expect(prep.searchRoots == ["~/code"])
        // 执行
        let exec = try #require(h.direct.executeRequests.first)
        #expect(exec.workspace == Fixtures.workspace(diff: "DIFF-A"))
        #expect(exec.cancellationToken === ticket.primary)
        #expect(h.lody.executeRequests.isEmpty)
        // 回写
        let delivery = try #require(h.sink.deliveries.first)
        #expect(h.sink.deliveries.count == 1)
        #expect(delivery.mode == .platformDraft)
        #expect(delivery.context.unifiedDiff == "DIFF-A")
        #expect(delivery.context.plan == plan)
        #expect(delivery.output == Fixtures.codeReview("all good"))
        // 结果条目
        #expect(delivered.status == .draftReady)
        #expect(delivered.executionOutput == Fixtures.codeReview("all good"))
        #expect(delivered.sessionID == "sess-1")
        #expect(delivered.sessionHandle?.sessionID == "sess-1")
        #expect(delivered.localReportPath == receipt.localReportPath?.path)
        #expect(delivered.errorMessage == nil)
        #expect(await h.store.item(item.id)?.status == .draftReady)
        // 用量
        #expect(usageRuns.count == 1)
        #expect(usageRuns.first?.engine == .claudeCode)
        #expect(usageRuns.first?.model == "sonnet")
        #expect(usageRuns.first?.isCouncilSecondary == false)
        #expect(await h.store.usageRuns.count == 1)
        // 进度：全部带本次 runID，按阶段推进
        let events = progress.events
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.runID == ticket.runID && $0.itemID == item.id })
        #expect(events.first?.status == .preparing)
        #expect(events.contains { $0.status == .running })
        #expect(events.last?.status == .publishing)
    }

    @Test("A direct reply delivery finishes the item (completed) instead of leaving a draft")
    func directReplyCompletesItem() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        h.direct.results[.claudeCode] = AgentRunResult(output: Fixtures.codeReview(), sessionHandle: nil, rawOutputText: "")

        let outcome = try await h.service.execute(request(item, plan: ExecutionPlan(engine: .claudeCode, model: "sonnet", deliveryMode: .directReply)))

        guard case .delivered(let delivered, _, _) = outcome else { Issue.record("expected .delivered"); return }
        #expect(delivered.status == .completed)
    }

    @Test("Items from non-code platforms are always delivered as local drafts")
    func nonCodePlatformsDeliverLocally() async throws {
        let h = Harness()
        let chat = Fixtures.chatItem()
        h.direct.results[.claudeCode] = AgentRunResult(
            output: .structuredReply(StructuredReplyResult(summary: "root cause", replyMarkdown: "…")),
            sessionHandle: nil,
            rawOutputText: ""
        )

        _ = try await h.service.execute(request(chat, plan: ExecutionPlan(engine: .claudeCode, model: "sonnet", deliveryMode: .platformDraft)))

        #expect(h.sink.deliveries.first?.mode == .localDraftOnly)
    }

    @Test("Background dispatch (Lody) persists a tracked draft without delivering; continuing the previous Lody session is reported")
    func lodyBackgroundDispatch() async throws {
        let h = Harness()
        let previous = PreviousReviewContext(
            previousItemID: "old", reviewedHeadSHA: "1111111", reviewedAt: Date(), engine: .lody, sessionID: "lody-1", reviewRound: 1
        )
        var item = Fixtures.prItem(status: .pendingConfirmation)
        item.previousReview = previous
        item.reviewRound = 2
        h.lody.results[.lody] = AgentRunResult(
            output: nil,
            sessionHandle: handle(.lody, "lody-1", launch: .nativeBackgroundSession),
            rawOutputText: "",
            wasBackgroundDispatched: true
        )
        let plan = ExecutionPlan(
            engine: .lody, model: "gemini-4-neon", launchMode: .nativeBackgroundSession,
            continuityMode: .continueSessionIncremental, previousReview: previous
        )

        let outcome = try await h.service.execute(request(item, plan: plan))

        guard case .backgroundDispatched(let dispatched, let dispatchedHandle, let continued, _) = outcome else {
            Issue.record("expected .backgroundDispatched, got \(outcome)"); return
        }
        #expect(h.sink.deliveries.isEmpty)
        #expect(h.direct.executeRequests.isEmpty)
        #expect(dispatchedHandle?.sessionID == "lody-1")
        #expect(continued)
        #expect(dispatched.status == .draftReady)
        #expect(dispatched.remoteSessionStatus == .running)
        #expect(dispatched.sessionID == "lody-1")
        #expect(await h.store.item(item.id)?.status == .draftReady)
    }

    @Test("Council: one shared workspace, two engines in parallel on primary/secondary tokens, synthesized output, two usage runs")
    func councilRun() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        let ticket = ExecutionRunTicket(itemID: item.id)
        let comment = CodeInlineComment(path: "Sources/A.swift", line: 10, severity: .warning, title: "nil check", body: "guard it")
        let outA = Fixtures.codeReview("A says", comments: [comment])
        let outB = Fixtures.codeReview("B says", comments: [comment])
        h.direct.results[.claudeCode] = AgentRunResult(output: outA, sessionHandle: handle(.claudeCode, "a"), rawOutputText: "", usage: usage)
        h.direct.results[.codex] = AgentRunResult(output: outB, sessionHandle: handle(.codex, "b"), rawOutputText: "", usage: usage)
        let plan = ExecutionPlan(
            engine: .claudeCode, model: "sonnet",
            launchMode: .nativeBackgroundSession, // 会诊必须强制托管运行
            councilPartner: CouncilPartner(engine: .codex, model: "gpt-5", effort: .high)
        )

        let outcome = try await h.service.execute(request(item, plan: plan, ticket: ticket))

        guard case .delivered(_, _, let usageRuns) = outcome else { Issue.record("expected .delivered, got \(outcome)"); return }
        #expect(h.direct.prepareRequests.count == 1)
        let execs = h.direct.executeRequests
        #expect(execs.count == 2)
        let primary = try #require(execs.first { $0.plan.engine == .claudeCode })
        let partner = try #require(execs.first { $0.plan.engine == .codex })
        #expect(primary.cancellationToken === ticket.primary)
        #expect(partner.cancellationToken === ticket.secondary)
        #expect(partner.plan.model == "gpt-5")
        #expect(partner.plan.effort == .high)
        #expect(primary.plan.launchMode == .managedStructuredRun)
        #expect(partner.plan.launchMode == .managedStructuredRun)
        #expect(primary.workspace == partner.workspace)

        // 两个模型在同一位置的发现合并为一条共识意见，并标明各自来自哪个模型（标签格式不做约束）
        guard case .codeReview(let merged)? = h.sink.deliveries.first?.output else {
            Issue.record("expected a synthesized code review to be delivered"); return
        }
        #expect(merged.comments.count == 1)
        let consensus = try #require(merged.comments.first)
        #expect(consensus.path == "Sources/A.swift")
        #expect(consensus.line == 10)
        #expect(consensus.body.contains("sonnet") && consensus.body.contains("gpt-5"))
        #expect(usageRuns.count == 2)
        #expect(usageRuns.filter(\.isCouncilSecondary).map(\.engine) == [.codex])
    }

    // MARK: cancellation

    @Test("Cancelled while preparing: nothing runs, nothing is delivered, nothing is marked failed")
    func cancelledDuringPrepare() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        let ticket = ExecutionRunTicket(itemID: item.id)
        h.direct.onPrepare = { ticket.cancel() }
        h.direct.results[.claudeCode] = AgentRunResult(output: Fixtures.codeReview(), sessionHandle: nil, rawOutputText: "")

        let outcome = try await h.service.execute(request(item, plan: ExecutionPlan(engine: .claudeCode, model: "sonnet"), ticket: ticket))

        guard case .cancelled(let itemID, let runID) = outcome else { Issue.record("expected .cancelled, got \(outcome)"); return }
        #expect(itemID == item.id)
        #expect(runID == ticket.runID)
        #expect(h.direct.executeRequests.isEmpty)
        #expect(h.sink.deliveries.isEmpty)
        #expect(await h.store.item(item.id)?.status != .failed)
    }

    @Test("Cancelled while the agent runs: result is discarded, not delivered, not marked failed")
    func cancelledDuringExecute() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        let ticket = ExecutionRunTicket(itemID: item.id)
        h.direct.onExecute = { _ in ticket.cancel() }
        h.direct.results[.claudeCode] = AgentRunResult(output: Fixtures.codeReview(), sessionHandle: nil, rawOutputText: "", usage: usage)

        let outcome = try await h.service.execute(request(item, plan: ExecutionPlan(engine: .claudeCode, model: "sonnet"), ticket: ticket))

        guard case .cancelled = outcome else { Issue.record("expected .cancelled, got \(outcome)"); return }
        #expect(h.sink.deliveries.isEmpty)
        #expect(await h.store.item(item.id)?.status != .failed)
    }

    // MARK: failures

    @Test("Agent failure: the error is thrown and the item is persisted as failed with a message")
    func agentFailureMarksItemFailed() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        h.direct.executeError = AgentRunnerError.processFailed(exitCode: 1, stderr: "Invalid API key")

        await #expect(throws: AgentRunnerError.self) {
            _ = try await h.service.execute(request(item, plan: ExecutionPlan(engine: .claudeCode, model: "sonnet")))
        }
        let stored = await h.store.item(item.id)
        #expect(stored?.status == .failed)
        #expect(stored?.errorMessage?.contains("Invalid API key") == true)
        #expect(h.sink.deliveries.isEmpty)
    }

    @Test("A managed run without structured output fails as unparseable (never delivered)")
    func unparseableOutputFails() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        h.direct.results[.claudeCode] = AgentRunResult(output: nil, sessionHandle: nil, rawOutputText: "garbage")

        await #expect(throws: AgentRunnerError.self) {
            _ = try await h.service.execute(request(item, plan: ExecutionPlan(engine: .claudeCode, model: "sonnet")))
        }
        #expect(h.sink.deliveries.isEmpty)
        #expect(await h.store.item(item.id)?.status == .failed)
    }

    @Test("Delivery failure: error thrown, item failed, but the tokens already spent are still recorded")
    func deliveryFailureStillRecordsUsage() async throws {
        let h = Harness()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        h.direct.results[.claudeCode] = AgentRunResult(output: Fixtures.codeReview(), sessionHandle: nil, rawOutputText: "", usage: usage)
        h.sink.error = GitHubConnectorError.pendingReviewAlreadyExists

        await #expect(throws: GitHubConnectorError.pendingReviewAlreadyExists) {
            _ = try await h.service.execute(request(item, plan: ExecutionPlan(engine: .claudeCode, model: "sonnet")))
        }
        #expect(await h.store.item(item.id)?.status == .failed)
        #expect(await h.store.usageRuns.count == 1)
    }

    @Test(
        "Store failures surface as PersistenceError instead of being swallowed",
        arguments: [PersistenceOperation.upsertUsageRun, .upsertItem]
    )
    func storeFailuresAreReported(operation: PersistenceOperation) async throws {
        let h = Harness()
        await h.store.fail(operation)
        let item = Fixtures.prItem(status: .pendingConfirmation)
        h.direct.results[.claudeCode] = AgentRunResult(output: Fixtures.codeReview(), sessionHandle: nil, rawOutputText: "", usage: usage)

        do {
            _ = try await h.service.execute(request(item, plan: ExecutionPlan(engine: .claudeCode, model: "sonnet")))
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
