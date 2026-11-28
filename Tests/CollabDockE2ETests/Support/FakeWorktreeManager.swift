import Foundation
@testable import CollabDockCore

/// 记录调用的 WorktreeManaging：用于验证 Lody 后端的工作区路由（哪些情况绝不能创建 worktree / 触发克隆）
/// 以及派发前是否刷新了本地项目里的 PR 引用。
final class FakeWorktreeManager: WorktreeManaging, @unchecked Sendable {
    struct PrepareCall {
        let item: CollaborationItem
        let preferredLocalPath: String?
        let useIsolatedWorktree: Bool
    }

    struct RefreshCall: Equatable {
        let path: String
        let number: Int
        let headRef: String
    }

    private let lock = NSLock()
    private var prepares: [PrepareCall] = []
    private var refreshes: [RefreshCall] = []

    var preparedContext = PreparedWorkspaceContext(
        workspaceURL: URL(fileURLWithPath: "/tmp/collabdock-fake-cache/worktrees/acme_backend-pr-7", isDirectory: true),
        isTemporaryWorktree: true
    )

    var prepareCalls: [PrepareCall] { lock.withLock { prepares } }
    /// 被刷新 PR 引用的本地项目路径（按调用顺序）
    var refreshCalls: [String] { lock.withLock { refreshes.map(\.path) } }
    var refreshDetails: [RefreshCall] { lock.withLock { refreshes } }

    func prepareContext(
        for item: CollaborationItem,
        searchRoots: [String],
        extraLocalRepoPaths: [String],
        preferredLocalPath: String?,
        useIsolatedWorktree: Bool,
        gitExecutablePath: String,
        environment: [String: String]
    ) async throws -> PreparedWorkspaceContext {
        lock.withLock {
            prepares.append(PrepareCall(
                item: item,
                preferredLocalPath: preferredLocalPath,
                useIsolatedWorktree: useIsolatedWorktree
            ))
        }
        return preparedContext
    }

    func refreshRemoteRefs(inRepositoryAt rootPath: String, code: CodeChangePayload, gitExecutablePath: String, environment: [String: String]) async {
        lock.withLock { refreshes.append(RefreshCall(path: rootPath, number: code.number, headRef: code.headRef)) }
    }
}
