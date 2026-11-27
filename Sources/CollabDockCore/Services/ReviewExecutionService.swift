import Foundation

/// Core 层审查执行管线输入请求
public struct ReviewExecutionRequest: Sendable {
    public let item: CollaborationItem
    public let plan: ExecutionPlan
    public let preset: TaskPreset
    public let ticket: ExecutionRunTicket
    public let searchRoots: [String]
    public let preferredLocalPath: String?
    public let environment: EnvironmentSnapshot?
    public let injectPresetPrompt: Bool
    public let reportsDirectory: URL?
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
        reportsDirectory: URL? = nil,
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
        self.reportsDirectory = reportsDirectory
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

/// 审查管线终态输出
public enum ReviewExecutionOutcome: Sendable {
    /// 完成结构化分析并通过连接器完成交付（单引擎或双模型会诊）
    case delivered(
        item: CollaborationItem,
        receipt: DeliveryReceipt,
        usageRuns: [ReviewUsageRun]
    )
    /// 已派发至原生后台会话（如 Lody 持久会话或 `claude --bg`），无需同步等待交付
    case backgroundDispatched(
        item: CollaborationItem,
        handle: AgentSessionHandle?,
        continuedExistingSession: Bool,
        usageRuns: [ReviewUsageRun]
    )
    /// 经由 `ExecutionRunTicket` 中止（不回写平台、不写入失败状态）
    case cancelled(itemID: String, runID: UUID)
}

/// Core 层审查执行编排服务（零 SwiftUI/AppKit 依赖）：
/// 串联「准备上下文 → 单引擎/双模型会诊后端执行 → 记账 → 交付回写 → 持久化」，全程以 `ExecutionRunTicket` 控制取消。
/// 约束：所有 `TaskStore` 写入失败（`upsertItem` / `upsertUsageRun`）必须抛出 `PersistenceError`，严禁 `try?` 静默吞错。
public struct ReviewExecutionService: Sendable {
    public let directBackend: any ExecutionBackend
    public let lodyBackend: any ExecutionBackend
    public let sink: any CollaborationSink
    public let store: any TaskStore
    public let clock: any ClockProviding

    public init(
        directBackend: any ExecutionBackend = DirectCLIBackend(),
        lodyBackend: any ExecutionBackend = LodyBackend(),
        sink: any CollaborationSink,
        store: any TaskStore,
        clock: any ClockProviding = SystemClock()
    ) {
        self.directBackend = directBackend
        self.lodyBackend = lodyBackend
        self.sink = sink
        self.store = store
        self.clock = clock
    }

    /// 按引擎选择对应的执行后端（`.lody` → `lodyBackend`，其余直连引擎 → `directBackend`）
    public func backend(for engine: AgentEngine) -> any ExecutionBackend {
        engine == .lody ? lodyBackend : directBackend
    }

    /// 执行完整审查流水线：
    /// 1. `backend.prepareWorkspace` 准备上下文（单引擎或双引擎共享同一只读 Worktree）
    /// 2. `backend.execute` 运行单引擎或双模型会诊（并行传 `ticket.primary` / `ticket.secondary`，会诊由 `CouncilSynthesizer` 汇总）
    /// 3. 记录 `ReviewUsageRun` 至 `store`（失败抛出 `PersistenceError`）
    /// 4. 后台派发直接持久化并返回 `.backgroundDispatched`；托管运行调用 `sink.deliver(..., context:)` 交付后持久化并返回 `.delivered`
    /// 5. 任意阶段检测到 `ticket.isCancelled` 即立即中止并返回 `.cancelled`，不交付且不落失败态
    public func execute(
        _ request: ReviewExecutionRequest,
        onProgress: @escaping @Sendable (ReviewExecutionProgress) -> Void = { _ in }
    ) async throws -> ReviewExecutionOutcome {
        let ticket = request.ticket
        let item = request.item
        let plan = request.plan

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

        // 1. 准备隔离上下文（双模型会诊固定走 directBackend 共享只读 Worktree）
        emit(.preparing, "正在准备隔离上下文...")
        let prepBackend = (plan.councilPartner != nil) ? directBackend : backend(for: plan.engine)
        let prepRequest = WorkspacePreparationRequest(
            item: item,
            plan: plan,
            searchRoots: request.searchRoots,
            preferredLocalPath: request.preferredLocalPath,
            environment: request.environment
        )

        let preparedContext: PreparedWorkspaceContext
        do {
            preparedContext = try await prepBackend.prepareWorkspace(for: prepRequest) { line in
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

        // 2. 启动单引擎或双模型并行会诊
        let finalOutput: ExecutionOutput
        let primaryHandle: AgentSessionHandle?
        var usageRuns: [ReviewUsageRun] = []

        if let partner = plan.councilPartner {
            emit(.running, "双模型会诊中：\(plan.engine.displayName) (\(plan.model)) × \(partner.engine.displayName) (\(partner.model))...")

            var primaryPlan = plan
            primaryPlan.launchMode = .managedStructuredRun
            var partnerPlan = plan
            partnerPlan.engine = partner.engine
            partnerPlan.model = partner.model
            partnerPlan.effort = partner.effort
            partnerPlan.launchMode = .managedStructuredRun

            let primaryRunReq = AgentRunRequest(
                item: item,
                plan: primaryPlan,
                preset: request.preset,
                workspace: preparedContext,
                environment: request.environment,
                injectPresetPrompt: request.injectPresetPrompt,
                cancellationToken: ticket.primary
            )
            let partnerRunReq = AgentRunRequest(
                item: item,
                plan: partnerPlan,
                preset: request.preset,
                workspace: preparedContext,
                environment: request.environment,
                injectPresetPrompt: request.injectPresetPrompt,
                cancellationToken: ticket.secondary
            )

            let primaryEngineName = primaryPlan.engine.displayName
            let partnerEngineName = partnerPlan.engine.displayName
            let primaryExecBackend = backend(for: primaryPlan.engine)
            let partnerExecBackend = backend(for: partnerPlan.engine)

            let (resA, resB): (AgentRunResult, AgentRunResult)
            do {
                async let runA = primaryExecBackend.execute(primaryRunReq) { line in
                    emit(.running, "[\(primaryEngineName)] \(line)")
                }
                async let runB = partnerExecBackend.execute(partnerRunReq) { line in
                    emit(.running, "[\(partnerEngineName)] \(line)")
                }
                (resA, resB) = try await (runA, runB)
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

            let runRecordA = makeUsageRun(
                request: request,
                plan: primaryPlan,
                engine: primaryPlan.engine,
                model: primaryPlan.model,
                effort: primaryPlan.effort,
                result: resA,
                isCouncilSecondary: false
            )
            let runRecordB = makeUsageRun(
                request: request,
                plan: partnerPlan,
                engine: partnerPlan.engine,
                model: partnerPlan.model,
                effort: partnerPlan.effort,
                result: resB,
                isCouncilSecondary: true
            )
            try await persist(.upsertUsageRun) { try await store.upsertUsageRun(runRecordA) }
            try await persist(.upsertUsageRun) { try await store.upsertUsageRun(runRecordB) }
            usageRuns = [runRecordA, runRecordB]

            guard let outA = resA.output, let outB = resB.output else {
                let err = AgentRunnerError.unparseableOutput(resA.rawOutputText + "\n" + resB.rawOutputText)
                try await persistFailedItem(item, error: err)
                throw err
            }

            finalOutput = CouncilSynthesizer.synthesize(
                primary: CouncilContribution(label: "\(primaryPlan.engine.displayName)/\(primaryPlan.model)", output: outA),
                secondary: CouncilContribution(label: "\(partnerPlan.engine.displayName)/\(partnerPlan.model)", output: outB)
            )
            primaryHandle = resA.sessionHandle ?? resB.sessionHandle
        } else {
            let isResumingSameLody = (plan.engine == .lody
                && plan.continuityMode == .continueSessionIncremental
                && plan.previousReview?.engine == .lody)
            emit(
                .running,
                isResumingSameLody
                    ? "正在向原 Lody 会话发送第 \(item.reviewRound) 轮复审追问..."
                    : "正在启动 \(plan.engine.displayName) (\(plan.model))..."
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

            let execBackend = backend(for: plan.engine)
            let runResult: AgentRunResult
            do {
                runResult = try await execBackend.execute(runRequest) { line in
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

            let runRecord = makeUsageRun(
                request: request,
                plan: plan,
                engine: plan.engine,
                model: plan.model,
                effort: plan.effort,
                result: runResult,
                isCouncilSecondary: false
            )
            try await persist(.upsertUsageRun) { try await store.upsertUsageRun(runRecord) }
            usageRuns = [runRecord]

            if runResult.wasBackgroundDispatched {
                var dispatched = item
                dispatched.status = .draftReady
                dispatched.progressMessage = nil
                dispatched.errorMessage = nil
                dispatched.sessionHandle = runResult.sessionHandle
                dispatched.sessionID = runResult.sessionHandle?.sessionID
                dispatched.remoteSessionStatus = (plan.engine == .lody) ? .running : .completed

                let summaryText: String
                if plan.engine == .lody {
                    summaryText = isResumingSameLody
                        ? "已向原 Lody 会话追加第 \(item.reviewRound) 轮增量复审，正在后台分析中..."
                        : "Lody 正在后台执行审查，可随时点「打开 Lody」查看实时进度。"
                } else {
                    summaryText = isResumingSameLody
                        ? "已向原 \(plan.engine.displayName) 会话追加第 \(item.reviewRound) 轮复审，可点「接管会话」查看。"
                        : "已派发为 \(plan.engine.displayName) 原生后台会话，可点「接管会话」查看。"
                }
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

            guard let output = runResult.output else {
                let err = AgentRunnerError.unparseableOutput(runResult.rawOutputText)
                try await persistFailedItem(item, error: err)
                throw err
            }
            finalOutput = output
            primaryHandle = runResult.sessionHandle
        }

        // 3. 交付结果（非代码托管平台始终只落本地草稿）
        emit(.publishing, "正在校验行号并生成 \(plan.deliveryMode.shortLabel(for: item.platform))...")

        let deliveryMode: DeliveryMode = (
            item.platform == sink.platform
            && ConnectorCatalog.capabilities(for: item.platform).requiresGitWorktree
        ) ? plan.deliveryMode : .localDraftOnly

        let deliveryContext = DeliveryContext(
            plan: plan,
            unifiedDiff: preparedContext.unifiedDiff,
            reportsDirectory: request.reportsDirectory
        )

        let receipt: DeliveryReceipt
        do {
            receipt = try await sink.deliver(
                output: finalOutput,
                for: item,
                mode: deliveryMode,
                context: deliveryContext
            )
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

        var delivered = item
        delivered.status = (receipt.deliveredMode == .platformDraft || receipt.deliveredMode == .localDraftOnly)
            ? .draftReady
            : .completed
        delivered.progressMessage = nil
        delivered.executionOutput = finalOutput
        delivered.sessionHandle = primaryHandle
        delivered.sessionID = primaryHandle?.sessionID
        delivered.localReportPath = receipt.localReportPath?.path
        delivered.deliveryURL = receipt.destinationURL
        delivered.errorMessage = nil

        try await persist(.upsertItem) { try await store.upsertItem(delivered) }
        return .delivered(item: delivered, receipt: receipt, usageRuns: usageRuns)
    }

    private func makeUsageRun(
        request: ReviewExecutionRequest,
        plan: ExecutionPlan,
        engine: AgentEngine,
        model: String,
        effort: ReasoningEffort,
        result: AgentRunResult,
        isCouncilSecondary: Bool
    ) -> ReviewUsageRun {
        let now = clock.now
        let effectiveUsage = result.usage ?? AgentUsageMetrics(
            durationSeconds: result.durationSeconds,
            metricKind: engine == .lody ? .pendingSync : .exact
        )
        return ReviewUsageRun(
            itemID: request.item.id,
            platform: request.item.platform,
            scope: request.item.scope,
            externalRef: request.item.externalRef,
            title: request.item.title,
            reviewRound: request.item.reviewRound,
            continuityMode: plan.continuityMode,
            engine: engine,
            lodyAgentName: engine == .lody ? request.lodyAgentDisplayName : nil,
            model: model,
            effort: effort,
            sessionID: result.sessionHandle?.sessionID,
            isCouncilSecondary: isCouncilSecondary,
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
