import Foundation
import CollabDockCore

/// 按平台构造协作连接器所需的上下文信息
public struct ConnectorBuildContext: Sendable {
    public let platform: PlatformKind
    public let rules: TriggerRules
    public let environment: EnvironmentSnapshot?

    public init(
        platform: PlatformKind,
        rules: TriggerRules = TriggerRules(),
        environment: EnvironmentSnapshot? = nil
    ) {
        self.platform = platform
        self.rules = rules
        self.environment = environment
    }
}

/// 按平台获取协作连接器能力的工厂协议（替代 `AppCoordinator` 内直接构造 `GitHubConnector`）
public protocol ConnectorFactory: Sendable {
    func makeSource(context: ConnectorBuildContext) -> (any CollaborationSource)?
    func makePRStatusQuery(context: ConnectorBuildContext) -> (any PRStatusQuerying)?
    func makePRFetcher(context: ConnectorBuildContext) -> (any PullRequestFetching)?
    func makeSink(context: ConnectorBuildContext) -> (any CollaborationSink)?
}

/// 生产默认连接器工厂：为 GitHub 提供完整连接器能力，为非代码平台提供本地报告交付回退
public struct DefaultConnectorFactory: ConnectorFactory {
    private let detector: any EnvironmentDetecting

    public init(detector: any EnvironmentDetecting = EnvironmentDetector()) {
        self.detector = detector
    }

    public func makeSource(context: ConnectorBuildContext) -> (any CollaborationSource)? {
        guard context.platform == .github else { return nil }
        return makeGitHubConnector(context: context)
    }

    public func makePRStatusQuery(context: ConnectorBuildContext) -> (any PRStatusQuerying)? {
        guard context.platform == .github else { return nil }
        return makeGitHubConnector(context: context)
    }

    public func makePRFetcher(context: ConnectorBuildContext) -> (any PullRequestFetching)? {
        guard context.platform == .github else { return nil }
        return makeGitHubConnector(context: context)
    }

    public func makeSink(context: ConnectorBuildContext) -> (any CollaborationSink)? {
        // GitHubConnector 的 deliver 对非代码平台会以 .localDraftOnly 写本地 Markdown 报告
        makeGitHubConnector(context: context)
    }

    private func makeGitHubConnector(context: ConnectorBuildContext) -> GitHubConnector {
        let knownHasNotifScope: Bool? = context.environment?.githubAuth.tokenSource == .ghCLI
            ? context.environment?.githubAuth.hasNotificationsScope
            : nil
        return GitHubConnector(
            tokenProvider: DefaultGitHubTokenProvider(
                detector: detector,
                ghExecutablePath: context.environment?.gh.executablePath
            ),
            includeReviewRequestedSearch: context.rules.enableReviewRequested,
            includeMentionsSearchFallback: context.rules.enableMention,
            knownNotificationsScope: knownHasNotifScope
        )
    }
}

/// 执行后端构造工厂协议（默认返回生产 `DirectCLIBackend` 与 `LodyBackend`，供 App 层单测注入 FakeBackend）
public protocol ExecutionBackendFactory: Sendable {
    func makeDirectBackend() -> any ExecutionBackend
    func makeLodyBackend(config: LodyConfig, catalog: LodyCatalogSnapshot?) -> any ExecutionBackend
}

/// 生产默认执行后端工厂
public struct DefaultExecutionBackendFactory: ExecutionBackendFactory {
    private let worktreeManager: any WorktreeManaging

    public init(worktreeManager: any WorktreeManaging = WorktreeManager()) {
        self.worktreeManager = worktreeManager
    }

    public func makeDirectBackend() -> any ExecutionBackend {
        DirectCLIBackend(worktreeManager: worktreeManager)
    }

    public func makeLodyBackend(config: LodyConfig, catalog: LodyCatalogSnapshot?) -> any ExecutionBackend {
        LodyBackend(config: config, catalog: catalog, worktreeManager: worktreeManager)
    }
}

/// 仅用于 `importPullRequest` 场景且工厂未提供 `CollaborationSource` 时的空源占位
struct NullCollaborationSource: CollaborationSource {
    let platform: PlatformKind

    func poll(_ request: PollRequest) async throws -> PollBatch {
        PollBatch(candidates: [])
    }
}
