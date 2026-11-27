import Foundation

/// Core 层审查执行管线输入请求（Lody-only）
public struct ReviewExecutionRequest: Sendable {
    public let item: CollaborationItem
    public let plan: ExecutionPlan
    public let preset: TaskPreset
    public let ticket: ExecutionRunTicket
    public let searchRoots: [String]
    public let preferredLocalPath: String?
    public let environment: EnvironmentSnapshot?
    public let injectPresetPrompt: Bool
    public let lodyAgentDisplayName: String?

    public init(
        item: CollaborationItem,
        plan: ExecutionPlan,
        preset: TaskPreset,
        ticket: ExecutionRunTicket,
        searchRoots: [String] = [],
        preferredLocalPath: String? = nil,
        environment: EnvironmentSnapshot? = nil,
        injectPresetPrompt: Bool = true,
        lodyAgentDisplayName: String? = nil
    ) {
        self.item = item
        self.plan = plan
        self.preset = preset
        self.ticket = ticket
        self.searchRoots = searchRoots
        self.preferredLocalPath = preferredLocalPath
        self.environment = environment
        self.injectPresetPrompt = injectPresetPrompt
        self.lodyAgentDisplayName = lodyAgentDisplayName
    }
}

/// 审查管线流式进度事件（携带 `runID` 供 UI 侧结合 `ExecutionRunRegistry` 校验防串台）
public struct ReviewExecutionProgress: Equatable, Sendable {
    public let itemID: String
    public let runID: UUID
    public let status: CollaborationTaskStatus
    public let message: String

    public init(
        itemID: String,
        runID: UUID,
        status: CollaborationTaskStatus,
        message: String
    ) {
        self.itemID = itemID
        self.runID = runID
        self.status = status
        self.message = message
    }
}

/// 审查管线终态输出（当前只剩 Lody 后台会话派发与用户中止）
public enum ReviewExecutionOutcome: Sendable {
    /// 已派发至 Lody 持久后台会话
    case backgroundDispatched(
        item: CollaborationItem,
        handle: AgentSessionHandle?,
        continuedExistingSession: Bool,
        usageRuns: [ReviewUsageRun]
    )
    /// 经由 `ExecutionRunTicket` 中止（不写入失败状态）
    case cancelled(itemID: String, runID: UUID)
}

/// Core 层审查执行编排服务（零 SwiftUI/AppKit 依赖，Lody-only）：
/// 串联「准备 Lody 上下文 → 派发 Lody 后台会话 → 记账 → 持久化」，全程以 `ExecutionRunTicket` 控制取消。
/// 约束：所有 `TaskStore` 写入失败（`upsertItem` / `upsertUsageRun`）必须抛出 `PersistenceError`，严禁 `try?` 静默吞错。
public struct ReviewExecutionService: Sendable {
    public let backend: any ExecutionBackend
    public let store: any TaskStore
    public let clock: any ClockProviding

    public init(
        backend: any ExecutionBackend = LodyBackend(),
        store: any TaskStore,
        clock: any ClockProviding = SystemClock()
    ) {
        self.backend = backend
        self.store = store
        self.clock = clock
    }

    /// 执行完整审查流水线：
    /// 1. 规整执行计划（始终落到 Lody 后台会话；外来引擎计划重置 model 为 `"default"`；外来上一轮会话降级为 `.freshSessionIncremental`）
    /// 2. `backend.prepareWorkspace` 准备 Lody 工作区上下文
    /// 3. `backend.execute` 派发至 Lody 后台会话（使用 `ticket.primary`）
    /// 4. 记录 `ReviewUsageRun` 至 `store`（失败抛出 `PersistenceError`）
    /// 5. 持久化被跟踪的卡片状态并返回 `.backgroundDispatched`；任意阶段取消即返回 `.cancelled`
    public func execute(
        _ request: ReviewExecutionRequest,
        onProgress: @escaping @Sendable (ReviewExecutionProgress) -> Void = { _ in }
    ) async throws -> ReviewExecutionOutcome {
        let ticket = request.ticket
        let item = request.item
        var plan = request.plan

        if plan.engine != .lody {
            plan.engine = .lody
            plan.model = "default"
        }
        plan.launchMode = .nativeBackgroundSession

        let canContinuePreviousLody: Bool = {
            guard let prev = plan.previousReview,
                  prev.engine == .lody,
                  let sid = prev.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sid.isEmpty else {
                return false
            }
            return true
        }()
        if plan.continuityMode == .continueSessionIncremental && !canContinuePreviousLody {
            plan.continuityMode = .freshSessionIncremental
        }
        let isResumingSameLody = (plan.continuityMode == .continueSessionIncremental && canContinuePreviousLody)

        let emit: @Sendable (CollaborationTaskStatus, String) -> Void = { status, message in
            guard !ticket.isCancelled else { return }
            onProgress(
                ReviewExecutionProgress(
                    itemID: item.id,
                    runID: ticket.runID,
                    status: status,
                    message: message
                )
            )
        }

        if ticket.isCancelled {
            return .cancelled(itemID: item.id, runID: ticket.runID)
        }

        // 1. 准备 Lody 工作区上下文
        emit(.preparing, CoreL10n.string("Preparing isolated context..."))
        let prepRequest = WorkspacePreparationRequest(
            item: item,
            plan: plan,
            searchRoots: request.searchRoots,
            preferredLocalPath: request.preferredLocalPath,
            environment: request.environment
        )

        let preparedContext: PreparedWorkspaceContext
        do {
            preparedContext = try await backend.prepareWorkspace(for: prepRequest) { line in
                emit(.preparing, line)
            }
        } catch {
            if ticket.isCancelled {
                return .cancelled(itemID: item.id, runID: ticket.runID)
            }
            try await persistFailedItem(item, error: error)
            throw error
        }

        if ticket.isCancelled {
            return .cancelled(itemID: item.id, runID: ticket.runID)
        }

        // 2. 派发 Lody 后台会话
        emit(
            .running,
            isResumingSameLody
                ? CoreL10n.format("Sending round %lld follow-up review to the existing Lody session...", item.reviewRound)
                : CoreL10n.format("Starting %@ (%@)...", AgentEngine.lody.displayName, plan.model)
        )

        let runRequest = AgentRunRequest(
            item: item,
            plan: plan,
            preset: request.preset,
            workspace: preparedContext,
            environment: request.environment,
            injectPresetPrompt: request.injectPresetPrompt,
            cancellationToken: ticket.primary
        )

        let runResult: AgentRunResult
        do {
            runResult = try await backend.execute(runRequest) { line in
                emit(.running, line)
            }
        } catch {
            if ticket.isCancelled {
                return .cancelled(itemID: item.id, runID: ticket.runID)
            }
            try await persistFailedItem(item, error: error)
            throw error
        }

        if ticket.isCancelled {
            return .cancelled(itemID: item.id, runID: ticket.runID)
        }

        // 3. 记录用量并落盘
        let runRecord = makeUsageRun(
            request: request,
            plan: plan,
            result: runResult
        )
        try await persist(.upsertUsageRun) { try await store.upsertUsageRun(runRecord) }
        let usageRuns = [runRecord]

        var dispatched = item
        dispatched.status = .draftReady
        dispatched.progressMessage = nil
        dispatched.errorMessage = nil
        dispatched.sessionHandle = runResult.sessionHandle
        dispatched.sessionID = runResult.sessionHandle?.sessionID
        dispatched.remoteSessionStatus = .running

        let summaryText = isResumingSameLody
            ? CoreL10n.format("Sent round %lld incremental re-review to the existing Lody session; analyzing in background...", item.reviewRound)
            : CoreL10n.string("Lody is reviewing in the background. Click \"Open Lody\" anytime to view live progress.")
        dispatched.executionOutput = .structuredReply(
            StructuredReplyResult(summary: summaryText, replyMarkdown: "")
        )

        try await persist(.upsertItem) { try await store.upsertItem(dispatched) }
        return .backgroundDispatched(
            item: dispatched,
            handle: runResult.sessionHandle,
            continuedExistingSession: isResumingSameLody,
            usageRuns: usageRuns
        )
    }

    private func makeUsageRun(
        request: ReviewExecutionRequest,
        plan: ExecutionPlan,
        result: AgentRunResult
    ) -> ReviewUsageRun {
        let now = clock.now
        let effectiveUsage = result.usage ?? AgentUsageMetrics(
            durationSeconds: result.durationSeconds,
            metricKind: .pendingSync
        )
        return ReviewUsageRun(
            itemID: request.item.id,
            platform: request.item.platform,
            scope: request.item.scope,
            externalRef: request.item.externalRef,
            title: request.item.title,
            reviewRound: request.item.reviewRound,
            continuityMode: plan.continuityMode,
            engine: .lody,
            lodyAgentName: request.lodyAgentDisplayName,
            model: plan.model,
            effort: plan.effort,
            sessionID: result.sessionHandle?.sessionID,
            isCouncilSecondary: false,
            usage: effectiveUsage,
            succeeded: true,
            createdAt: now,
            syncedAt: effectiveUsage.metricKind == .exact ? now : nil
        )
    }

    private func persistFailedItem(_ item: CollaborationItem, error: any Error) async throws {
        var failed = item
        failed.status = .failed
        failed.progressMessage = nil
        failed.errorMessage = error.localizedDescription
        try await persist(.upsertItem) {
            try await store.upsertItem(failed)
        }
    }

    private func persist<T>(
        _ operation: PersistenceOperation,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch let err as PersistenceError {
            throw err
        } catch {
            throw PersistenceError(operation: operation, underlying: error)
        }
    }
}
