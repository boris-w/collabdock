import Foundation

// MARK: - 多平台协作连接器抽象契约（关联 ADR-005）

public struct SyncCursor: Codable, Hashable, Sendable {
    public let value: String
    public let updatedAt: Date

    public init(value: String, updatedAt: Date = Date()) {
        self.value = value
        self.updatedAt = updatedAt
    }
}

public struct PolledCollaborationCandidate: Hashable, Sendable {
    public let dedupeKey: String
    public let event: IncomingCollaborationEvent
    public let item: CollaborationItem

    public init(
        dedupeKey: String,
        event: IncomingCollaborationEvent,
        item: CollaborationItem
    ) {
        self.dedupeKey = dedupeKey
        self.event = event
        self.item = item
    }
}

public struct RateLimitSnapshot: Codable, Equatable, Sendable {
    public let limit: Int
    public let remaining: Int
    public let resetAt: Date?

    public init(limit: Int, remaining: Int, resetAt: Date? = nil) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
    }
}

public struct PollBatch: Sendable {
    public let candidates: [PolledCollaborationCandidate]
    public let nextCursor: SyncCursor?
    public let suggestedPollIntervalSeconds: Int?
    public let diagnosticMessage: String?
    public let wasNotModified: Bool
    public let rateLimit: RateLimitSnapshot?
    public let updatedPRFingerprints: [String: String]

    public init(
        candidates: [PolledCollaborationCandidate],
        nextCursor: SyncCursor? = nil,
        suggestedPollIntervalSeconds: Int? = nil,
        diagnosticMessage: String? = nil,
        wasNotModified: Bool = false,
        rateLimit: RateLimitSnapshot? = nil,
        updatedPRFingerprints: [String: String] = [:]
    ) {
        self.candidates = candidates
        self.nextCursor = nextCursor
        self.suggestedPollIntervalSeconds = suggestedPollIntervalSeconds
        self.diagnosticMessage = diagnosticMessage
        self.wasNotModified = wasNotModified
        self.rateLimit = rateLimit
        self.updatedPRFingerprints = updatedPRFingerprints
    }
}

public struct DeliveryReceipt: Codable, Hashable, Sendable {
    public let deliveredMode: DeliveryMode
    public let destinationURL: URL?
    public let localReportPath: URL?
    public let deliveredAt: Date

    public init(
        deliveredMode: DeliveryMode,
        destinationURL: URL? = nil,
        localReportPath: URL? = nil,
        deliveredAt: Date = Date()
    ) {
        self.deliveredMode = deliveredMode
        self.destinationURL = destinationURL
        self.localReportPath = localReportPath
        self.deliveredAt = deliveredAt
    }
}

public struct ConnectorCapabilities: Hashable, Sendable {
    public let platform: PlatformKind
    public let supportedDeliveryModes: [DeliveryMode]
    public let defaultDeliveryMode: DeliveryMode
    public let requiresGitWorktree: Bool
    public let isImplementedInV1: Bool
    public let summary: String

    public init(
        platform: PlatformKind,
        supportedDeliveryModes: [DeliveryMode],
        defaultDeliveryMode: DeliveryMode,
        requiresGitWorktree: Bool,
        isImplementedInV1: Bool,
        summary: String
    ) {
        self.platform = platform
        self.supportedDeliveryModes = supportedDeliveryModes
        self.defaultDeliveryMode = defaultDeliveryMode
        self.requiresGitWorktree = requiresGitWorktree
        self.isImplementedInV1 = isImplementedInV1
        self.summary = summary
    }
}

/// 交付回写上下文（将执行计划、Diff 行号校验输入与本地报告目录收拢为统一值对象）
public struct DeliveryContext: Sendable {
    public let plan: ExecutionPlan?
    public let unifiedDiff: String?
    public let reportsDirectory: URL?

    public init(
        plan: ExecutionPlan? = nil,
        unifiedDiff: String? = nil,
        reportsDirectory: URL? = nil
    ) {
        self.plan = plan
        self.unifiedDiff = unifiedDiff
        self.reportsDirectory = reportsDirectory
    }
}

/// 批量查询远端 PR 状态（Approve / Merged / Closed / Request Changes）的统一返回结果
public struct PRStatusBatchResult: Equatable, Sendable {
    public let viewerLogin: String?
    public let snapshots: [String: GitHubConnector.PRRemoteStatusSnapshot]

    public init(
        viewerLogin: String? = nil,
        snapshots: [String: GitHubConnector.PRRemoteStatusSnapshot] = [:]
    ) {
        self.viewerLogin = viewerLogin
        self.snapshots = snapshots
    }
}

/// 单次轮询请求（携带游标、慢通道对齐标志、已知 PR `updated_at` 指纹与当前登录用户名，确保跨轮次零配额优化与同提交复审识别可随协议传递）
public struct PollRequest: Equatable, Sendable {
    public var cursor: SyncCursor?
    public var reconcileNow: Bool
    public var knownFingerprints: [String: String]
    public var viewerLogin: String?

    public init(
        cursor: SyncCursor? = nil,
        reconcileNow: Bool = true,
        knownFingerprints: [String: String] = [:],
        viewerLogin: String? = nil
    ) {
        self.cursor = cursor
        self.reconcileNow = reconcileNow
        self.knownFingerprints = knownFingerprints
        self.viewerLogin = viewerLogin
    }
}

/// 事件源协议（各平台按需实现：GitHub 条件轮询、GitLab API、飞书事件订阅、Slack Socket Mode 等）
public protocol CollaborationSource: Sendable {
    var platform: PlatformKind { get }
    func poll(_ request: PollRequest) async throws -> PollBatch
}

public extension CollaborationSource {
    func poll(cursor: SyncCursor?) async throws -> PollBatch {
        try await poll(PollRequest(cursor: cursor))
    }
}

/// 结果回写协议（各平台按自身原生能力落草稿或发回复，支持传入 Diff / Plan / 报告目录上下文）
public protocol CollaborationSink: Sendable {
    var platform: PlatformKind { get }
    func supportedDeliveryModes(for item: CollaborationItem) -> [DeliveryMode]
    func deliver(
        output: ExecutionOutput,
        for item: CollaborationItem,
        mode: DeliveryMode,
        context: DeliveryContext
    ) async throws -> DeliveryReceipt
}

public extension CollaborationSink {
    func deliver(
        output: ExecutionOutput,
        for item: CollaborationItem,
        mode: DeliveryMode
    ) async throws -> DeliveryReceipt {
        try await deliver(output: output, for: item, mode: mode, context: DeliveryContext())
    }
}

/// 支持按链接或 `owner/repo#number` 手动拉取单条 PR / MR 的连接器能力
public protocol PullRequestFetching: Sendable {
    var platform: PlatformKind { get }
    func fetchPullRequest(reference: String) async throws -> CollaborationItem
}

/// 支持批量查询收件箱活跃 PR 远端状态的连接器能力
public protocol PRStatusQuerying: Sendable {
    var platform: PlatformKind { get }
    func fetchPRStatusSnapshots(targets: [PRStateReconciler.Target]) async throws -> PRStatusBatchResult
}

/// 组合型连接器协议（Source + Sink + 能力声明）
public protocol CollaborationConnector: CollaborationSource, CollaborationSink {
    var capabilities: ConnectorCapabilities { get }
}

/// 代码托管平台完整连接器协议（轮询 + 含 Diff 交付 + 单条 PR 拉取 + 远端状态批量对齐）
public protocol CodeReviewConnector: CollaborationConnector, PullRequestFetching, PRStatusQuerying {}

/// 内置连接器能力目录，驱动 UI 与执行策略自适应，避免各处硬编码 if platform == .github
public enum ConnectorCatalog {
    public static func capabilities(for platform: PlatformKind) -> ConnectorCapabilities {
        switch platform {
        case .github:
            return ConnectorCapabilities(
                platform: .github,
                supportedDeliveryModes: [.platformDraft, .localDraftOnly, .directReply],
                defaultDeliveryMode: .platformDraft,
                requiresGitWorktree: true,
                isImplementedInV1: true,
                summary: "条件轮询 Notifications / PR Review，支持 Pending 草稿回写"
            )
        case .gitlab:
            return ConnectorCapabilities(
                platform: .gitlab,
                supportedDeliveryModes: [.platformDraft, .localDraftOnly, .directReply],
                defaultDeliveryMode: .platformDraft,
                requiresGitWorktree: true,
                isImplementedInV1: false,
                summary: "Merge Request @mention 与 Draft Notes（规划扩展）"
            )
        case .feishu:
            return ConnectorCapabilities(
                platform: .feishu,
                supportedDeliveryModes: [.localDraftOnly, .directReply],
                defaultDeliveryMode: .localDraftOnly,
                requiresGitWorktree: false,
                isImplementedInV1: false,
                summary: "飞书群聊 / 文档评论 @我，本地生成排查回复草稿（规划扩展）"
            )
        case .slack:
            return ConnectorCapabilities(
                platform: .slack,
                supportedDeliveryModes: [.localDraftOnly, .directReply],
                defaultDeliveryMode: .localDraftOnly,
                requiresGitWorktree: false,
                isImplementedInV1: false,
                summary: "Slack Thread @mention，支持关联本地代码库只读排查（规划扩展）"
            )
        case .linear:
            return ConnectorCapabilities(
                platform: .linear,
                supportedDeliveryModes: [.localDraftOnly, .directReply],
                defaultDeliveryMode: .localDraftOnly,
                requiresGitWorktree: false,
                isImplementedInV1: false,
                summary: "Linear Issue 指派与评论触发，输出根因分析与方案（规划扩展）"
            )
        case .jira:
            return ConnectorCapabilities(
                platform: .jira,
                supportedDeliveryModes: [.localDraftOnly, .directReply],
                defaultDeliveryMode: .localDraftOnly,
                requiresGitWorktree: false,
                isImplementedInV1: false,
                summary: "Jira 工单评论与指派触发（规划扩展）"
            )
        case .customWebhook:
            return ConnectorCapabilities(
                platform: .customWebhook,
                supportedDeliveryModes: [.localDraftOnly, .directReply],
                defaultDeliveryMode: .localDraftOnly,
                requiresGitWorktree: false,
                isImplementedInV1: false,
                summary: "自定义 Webhook / SSE 桥接接入任意团队内部系统（规划扩展）"
            )
        }
    }

    public static func supportedDeliveryModes(for item: CollaborationItem) -> [DeliveryMode] {
        switch item.payload {
        case .codeChange:
            return capabilities(for: item.platform).supportedDeliveryModes
        case .issueTicket, .conversation:
            return [.localDraftOnly, .directReply]
        }
    }

    public static func defaultDeliveryMode(for item: CollaborationItem) -> DeliveryMode {
        switch item.payload {
        case .codeChange:
            return capabilities(for: item.platform).defaultDeliveryMode
        case .issueTicket, .conversation:
            return .localDraftOnly
        }
    }
}
