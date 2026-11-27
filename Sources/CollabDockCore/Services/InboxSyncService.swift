import Foundation

/// 收件箱同步跨轮次持久状态（由调用方持有并在每次同步前后传递，便于纯函数式测试）
public struct InboxSyncState: Equatable, Sendable {
    public var rateLimitedUntil: Date?
    public var lastReconcileAt: Date?
    public var lastPRStateReconcileAt: Date?
    public var knownPRFingerprints: [String: String]
    public var effectivePollIntervalSeconds: Int

    public init(
        rateLimitedUntil: Date? = nil,
        lastReconcileAt: Date? = nil,
        lastPRStateReconcileAt: Date? = nil,
        knownPRFingerprints: [String: String] = [:],
        effectivePollIntervalSeconds: Int = 60
    ) {
        self.rateLimitedUntil = rateLimitedUntil
        self.lastReconcileAt = lastReconcileAt
        self.lastPRStateReconcileAt = lastPRStateReconcileAt
        self.knownPRFingerprints = knownPRFingerprints
        self.effectivePollIntervalSeconds = effectivePollIntervalSeconds
    }
}

/// 同步限流与退避状态输出
public struct SyncBackoffState: Equatable, Sendable {
    public let isRateLimited: Bool
    public let rateLimitedUntil: Date?
    public let retryAfterSeconds: Int?
    public let wasSkippedDueToBackoff: Bool
    public let errorMessage: String?

    public init(
        isRateLimited: Bool = false,
        rateLimitedUntil: Date? = nil,
        retryAfterSeconds: Int? = nil,
        wasSkippedDueToBackoff: Bool = false,
        errorMessage: String? = nil
    ) {
        self.isRateLimited = isRateLimited
        self.rateLimitedUntil = rateLimitedUntil
        self.retryAfterSeconds = retryAfterSeconds
        self.wasSkippedDueToBackoff = wasSkippedDueToBackoff
        self.errorMessage = errorMessage
    }

    public static let none = SyncBackoffState()
}

/// Core 层产出的纯数据通知事件（不依赖 AppKit / UserNotifications）
public enum InboxNotification: Equatable, Sendable {
    case incomingTask(CollaborationItem)
}

/// 单次同步请求输入
public struct InboxSyncRequest: Sendable {
    public let manual: Bool
    public let existingItems: [CollaborationItem]
    public let rules: TriggerRules
    public let currentHandle: String
    public let autoCompleteApprovedOrClosedPRs: Bool
    public let previousState: InboxSyncState

    public init(
        manual: Bool = false,
        existingItems: [CollaborationItem] = [],
        rules: TriggerRules = TriggerRules(),
        currentHandle: String = "",
        autoCompleteApprovedOrClosedPRs: Bool = true,
        previousState: InboxSyncState = InboxSyncState()
    ) {
        self.manual = manual
        self.existingItems = existingItems
        self.rules = rules
        self.currentHandle = currentHandle
        self.autoCompleteApprovedOrClosedPRs = autoCompleteApprovedOrClosedPRs
        self.previousState = previousState
    }
}

/// 单次同步输出结果
public struct InboxSyncResult: Equatable, Sendable {
    public let newItems: [CollaborationItem]
    public let supersededItems: [CollaborationItem]
    public let prStateUpdates: [PRStateReconciler.Update]
    public let notifications: [InboxNotification]
    public let state: InboxSyncState
    public let backoff: SyncBackoffState
    public let wasNotModified: Bool
    public let rateLimit: RateLimitSnapshot?
    public let diagnosticMessage: String?

    public init(
        newItems: [CollaborationItem] = [],
        supersededItems: [CollaborationItem] = [],
        prStateUpdates: [PRStateReconciler.Update] = [],
        notifications: [InboxNotification] = [],
        state: InboxSyncState = InboxSyncState(),
        backoff: SyncBackoffState = .none,
        wasNotModified: Bool = false,
        rateLimit: RateLimitSnapshot? = nil,
        diagnosticMessage: String? = nil
    ) {
        self.newItems = newItems
        self.supersededItems = supersededItems
        self.prStateUpdates = prStateUpdates
        self.notifications = notifications
        self.state = state
        self.backoff = backoff
        self.wasNotModified = wasNotModified
        self.rateLimit = rateLimit
        self.diagnosticMessage = diagnosticMessage
    }
}

/// PR 远端状态对齐输出结果
public struct PRReconcileResult: Equatable, Sendable {
    public let updates: [PRStateReconciler.Update]
    public let updatedItems: [CollaborationItem]
    public let reconciledAt: Date?

    public init(
        updates: [PRStateReconciler.Update] = [],
        updatedItems: [CollaborationItem] = [],
        reconciledAt: Date? = nil
    ) {
        self.updates = updates
        self.updatedItems = updatedItems
        self.reconciledAt = reconciledAt
    }
}

/// Core 层收件箱同步编排服务（零 SwiftUI/AppKit 依赖）：
/// 负责条件轮询、限流退避、去重过滤、规则引擎匹配、复审上下文挂载、远端 PR 状态对齐与手动导入。
/// 约束：所有 `TaskStore` 读写失败必须包装为 `PersistenceError` 向上抛出，严禁 `try?` 静默吞错。
public struct InboxSyncService: Sendable {
    public let source: any CollaborationSource
    public let prStatusQuery: (any PRStatusQuerying)?
    public let prFetcher: (any PullRequestFetching)?
    public let store: any TaskStore
    public let ruleEngine: TriggerRuleEngine
    public let clock: any ClockProviding

    public init(
        source: any CollaborationSource,
        prStatusQuery: (any PRStatusQuerying)? = nil,
        prFetcher: (any PullRequestFetching)? = nil,
        store: any TaskStore,
        ruleEngine: TriggerRuleEngine = TriggerRuleEngine(),
        clock: any ClockProviding = SystemClock()
    ) {
        self.source = source
        self.prStatusQuery = prStatusQuery ?? (source as? any PRStatusQuerying)
        self.prFetcher = prFetcher ?? (source as? any PullRequestFetching)
        self.store = store
        self.ruleEngine = ruleEngine
        self.clock = clock
    }

    /// 执行一次完整同步：
    /// - 命中退避窗口且非手动刷新时直接短路返回 `backoff.wasSkippedDueToBackoff = true`
    /// - 连接器返回 `GitHubConnectorError.rateLimited` 时转为 `backoff` 返回而非丢弃退避时间
    /// - 任意存储操作失败必须抛出 `PersistenceError`（不可静默吞掉）
    public func sync(_ request: InboxSyncRequest) async throws -> InboxSyncResult {
        let now = clock.now
        var state = request.previousState

        if !request.manual, let until = state.rateLimitedUntil, until > now {
            let remaining = max(1, Int(ceil(until.timeIntervalSince(now))))
            return InboxSyncResult(
                state: state,
                backoff: SyncBackoffState(
                    isRateLimited: true,
                    rateLimitedUntil: until,
                    retryAfterSeconds: remaining,
                    wasSkippedDueToBackoff: true,
                    errorMessage: nil
                )
            )
        }

        // 仅在首次启动、手动刷新或距上次对齐满 15 分钟时走慢通道 review-requested Search 对齐
        let shouldReconcile = request.manual
            || state.lastReconcileAt == nil
            || now.timeIntervalSince(state.lastReconcileAt!) >= 900

        let previousCursor = try await persist(.loadCursor) {
            try await store.loadCursor(for: source.platform)
        }

        let trimmedHandle = request.currentHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        let pollRequest = PollRequest(
            cursor: previousCursor,
            reconcileNow: shouldReconcile,
            knownFingerprints: state.knownPRFingerprints,
            viewerLogin: trimmedHandle.isEmpty ? nil : trimmedHandle
        )

        let batch: PollBatch
        do {
            batch = try await source.poll(pollRequest)
        } catch let ghErr as GitHubConnectorError {
            if case .rateLimited(let retryAfter) = ghErr {
                let until = now.addingTimeInterval(TimeInterval(retryAfter))
                state.rateLimitedUntil = until
                return InboxSyncResult(
                    state: state,
                    backoff: SyncBackoffState(
                        isRateLimited: true,
                        rateLimitedUntil: until,
                        retryAfterSeconds: retryAfter,
                        wasSkippedDueToBackoff: false,
                        errorMessage: ghErr.localizedDescription
                    )
                )
            }
            throw ghErr
        }

        state.rateLimitedUntil = nil
        state.knownPRFingerprints = batch.updatedPRFingerprints
        if shouldReconcile {
            state.lastReconcileAt = now
        }
        if let suggestedInterval = batch.suggestedPollIntervalSeconds {
            state.effectivePollIntervalSeconds = max(60, suggestedInterval)
        }

        var knownItems = request.existingItems
        var existingIDs = Set(request.existingItems.map(\.id))
        var pendingTargets = Set(
            request.existingItems
                .filter { $0.status == .pendingConfirmation }
                .map(Self.targetKey(for:))
        )
        var newItems: [CollaborationItem] = []
        var supersededItems: [CollaborationItem] = []
        var notifications: [InboxNotification] = []

        var acceptedCandidates: [(index: Int, candidate: PolledCollaborationCandidate, hints: ParsedTriggerHints)] = []
        for (index, candidate) in batch.candidates.enumerated() {
            let alreadySeen = try await persist(.hasSeen) {
                try await store.hasSeen(dedupeKey: candidate.dedupeKey)
            }
            if alreadySeen { continue }

            let evaluation = ruleEngine.evaluate(
                event: candidate.event,
                currentHandle: request.currentHandle,
                rules: request.rules
            )
            guard case .accept(let hints) = evaluation else {
                continue
            }
            acceptedCandidates.append((index: index, candidate: candidate, hints: hints))
        }

        // 同一次同步里同一 PR 命中多个事件时优先保留 reviewRequested，其次保持原顺序
        let prioritized = acceptedCandidates.sorted { lhs, rhs in
            let lp = Self.triggerPriority(lhs.candidate.event.triggerKind)
            let rp = Self.triggerPriority(rhs.candidate.event.triggerKind)
            if lp != rp { return lp < rp }
            return lhs.index < rhs.index
        }

        for entry in prioritized {
            let candidate = entry.candidate
            let hints = entry.hints
            let targetKey = Self.targetKey(for: candidate.item)

            // 已有同 ID 条目，或同 PR 已存在一张「待确认」卡片时，仅标记已见，绝不重复入箱或重复通知
            if existingIDs.contains(candidate.item.id) || pendingTargets.contains(targetKey) {
                try await persist(.markSeen) {
                    try await store.markSeen(dedupeKey: candidate.dedupeKey, itemID: candidate.item.id)
                }
                continue
            }

            var newItem = candidate.item
            newItem.suggestedEngine = hints.engine
            newItem.suggestedModel = hints.model
            newItem.suggestedPresetID = hints.focus
            if let prev = Self.findPreviousReview(for: newItem, in: knownItems) {
                newItem.previousReview = prev
                newItem.reviewRound = prev.reviewRound + 1
            }

            try await persist(.markSeen) {
                try await store.markSeen(dedupeKey: candidate.dedupeKey, itemID: newItem.id)
            }

            // 新一轮卡片入箱时，将同 PR 仍停留在收件箱中的已处理卡片（草稿就绪 / 失败）自动归档为 .superseded，保留历史审查内容
            for i in knownItems.indices {
                guard knownItems[i].id != newItem.id,
                      Self.targetKey(for: knownItems[i]) == targetKey,
                      knownItems[i].status == .draftReady || knownItems[i].status == .failed else {
                    continue
                }
                knownItems[i].status = .completed
                knownItems[i].completionReason = .superseded
                let archived = knownItems[i]
                try await persist(.upsertItem) {
                    try await store.upsertItem(archived)
                }
                supersededItems.append(archived)
            }

            try await persist(.upsertItem) {
                try await store.upsertItem(newItem)
            }

            existingIDs.insert(newItem.id)
            if newItem.status == .pendingConfirmation {
                pendingTargets.insert(targetKey)
            }
            knownItems.insert(newItem, at: 0)
            newItems.append(newItem)
            notifications.append(.incomingTask(newItem))
        }

        if let nextCursor = batch.nextCursor {
            try await persist(.saveCursor) {
                try await store.saveCursor(nextCursor, for: source.platform)
            }
        }

        var prStateUpdates: [PRStateReconciler.Update] = []
        if request.autoCompleteApprovedOrClosedPRs, prStatusQuery != nil {
            let reconcileResult = try await reconcilePRStates(
                items: knownItems,
                viewerLogin: request.currentHandle,
                force: request.manual,
                lastReconcileAt: state.lastPRStateReconcileAt
            )
            prStateUpdates = reconcileResult.updates
            if let reconciledAt = reconcileResult.reconciledAt {
                state.lastPRStateReconcileAt = reconciledAt
            }
        }

        return InboxSyncResult(
            newItems: newItems,
            supersededItems: supersededItems,
            prStateUpdates: prStateUpdates,
            notifications: notifications,
            state: state,
            backoff: .none,
            wasNotModified: batch.wasNotModified,
            rateLimit: batch.rateLimit,
            diagnosticMessage: batch.diagnosticMessage
        )
    }

    /// 独立执行收件箱活跃 PR 的远端状态批量对齐（带 25 秒节流，`force: true` 跳过节流；持久化失败抛出 `PersistenceError`）
    public func reconcilePRStates(
        items: [CollaborationItem],
        viewerLogin: String,
        force: Bool = false,
        lastReconcileAt: Date? = nil
    ) async throws -> PRReconcileResult {
        guard let prStatusQuery else {
            return PRReconcileResult()
        }

        let now = clock.now
        if !force, let last = lastReconcileAt, now.timeIntervalSince(last) < 25 {
            return PRReconcileResult()
        }

        let targets = PRStateReconciler.targets(in: items)
        guard !targets.isEmpty else {
            return PRReconcileResult()
        }

        let batch = try await prStatusQuery.fetchPRStatusSnapshots(targets: targets)
        let viewer = batch.viewerLogin ?? viewerLogin
        guard !batch.snapshots.isEmpty else {
            return PRReconcileResult(reconciledAt: now)
        }

        let updates = PRStateReconciler.updates(
            for: items,
            snapshots: batch.snapshots,
            viewerLogin: viewer
        )
        var itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var updatedItems: [CollaborationItem] = []
        updatedItems.reserveCapacity(updates.count)

        for update in updates {
            guard var target = itemsByID[update.itemID] else { continue }
            PRStateReconciler.apply(update, to: &target)
            itemsByID[update.itemID] = target
            updatedItems.append(target)
        }

        for updated in updatedItems {
            try await persist(.upsertItem) {
                try await store.upsertItem(updated)
            }
        }

        return PRReconcileResult(
            updates: updates,
            updatedItems: updatedItems,
            reconciledAt: now
        )
    }

    /// 手动导入单个 PR（自动挂载复审记忆、避免覆盖同 SHA 已完成历史记录、持久化失败抛出 `PersistenceError`）
    public func importPullRequest(
        reference: String,
        existingItems: [CollaborationItem]
    ) async throws -> CollaborationItem {
        guard let prFetcher else {
            throw GitHubConnectorError.httpError(statusCode: 501, message: "当前连接器不支持手动拉取 PR")
        }

        var item = try await prFetcher.fetchPullRequest(reference: reference)
        if let prev = Self.findPreviousReview(for: item, in: existingItems) {
            item.previousReview = prev
            item.reviewRound = prev.reviewRound + 1
        }

        // 同 SHA 已有已完成或草稿就绪历史记录时，生成新轮次 ID 保留上轮历史
        if let existing = existingItems.first(where: { $0.id == item.id }),
           existing.status == .draftReady || existing.status == .completed {
            let reReviewID = "\(item.id):r\(item.reviewRound)"
            item = CollaborationItem(
                id: reReviewID,
                platform: item.platform,
                itemKind: item.itemKind,
                scope: item.scope,
                externalRef: item.externalRef,
                title: item.title,
                url: item.url,
                author: item.author,
                triggeredBy: item.triggeredBy,
                triggerKind: item.triggerKind,
                triggerBody: item.triggerBody,
                payload: item.payload,
                createdAt: clock.now,
                status: .pendingConfirmation,
                previousReview: item.previousReview,
                reviewRound: item.reviewRound
            )
        }

        try await persist(.upsertItem) {
            try await store.upsertItem(item)
        }
        return item
    }

    /// 检索同平台、同仓库、同外部编号的最近已完成/草稿就绪审查记录，构造复审上下文
    public static func findPreviousReview(
        for item: CollaborationItem,
        in existingItems: [CollaborationItem],
        defaultEngine: AgentEngine = .claudeCode
    ) -> PreviousReviewContext? {
        let targetScope = item.scope.lowercased()
        let targetRef = item.externalRef.lowercased()
        guard let prior = existingItems.first(where: { existing in
            existing.id != item.id
                && existing.platform == item.platform
                && existing.scope.lowercased() == targetScope
                && existing.externalRef.lowercased() == targetRef
                && (existing.status == .draftReady || existing.status == .completed)
        }) else {
            return nil
        }

        let priorSHA: String = {
            if case .codeChange(let code) = prior.payload {
                return code.headSHA
            }
            return ""
        }()
        let engine = prior.sessionHandle?.engine ?? defaultEngine
        let sessionID = prior.sessionHandle?.sessionID ?? prior.sessionID
        let rawSummary = prior.executionOutput?.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = rawSummary.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) }

        return PreviousReviewContext(
            previousItemID: prior.id,
            reviewedHeadSHA: priorSHA,
            reviewedAt: prior.createdAt,
            engine: engine,
            model: nil,
            sessionID: sessionID,
            summarySnippet: snippet,
            reviewRound: prior.reviewRound
        )
    }

    private static func targetKey(for item: CollaborationItem) -> String {
        "\(item.platform.rawValue)|\(item.scope.lowercased())|\(item.externalRef.lowercased())"
    }

    private static func triggerPriority(_ kind: TriggerKind) -> Int {
        switch kind {
        case .reviewRequested: return 0
        case .assigned: return 1
        case .mention, .teamMention, .threadReply: return 2
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
