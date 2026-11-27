import Foundation
@testable import CollabDockCore

/// 记录调用的 WorktreeManaging：用于验证 Lody 后端的工作区路由（哪些情况绝不能创建 worktree / 触发克隆）
final class FakeWorktreeManager: WorktreeManaging, @unchecked Sendable {
    struct PrepareCall {
        let item: CollaborationItem
        let preferredLocalPath: String?
        let useIsolatedWorktree: Bool
        let previousReviewedSHA: String?
    }

    private let lock = NSLock()
    private var prepares: [PrepareCall] = []
    private var refreshes: [String] = []
    private var incrementals: [(path: String, previousSHA: String)] = []

    var preparedContext = PreparedWorkspaceContext(
        workspaceURL: URL(fileURLWithPath: "/tmp/collabdock-fake-cache/worktrees/acme_backend-pr-7", isDirectory: true),
        isTemporaryWorktree: true,
        unifiedDiff: "FULL-DIFF"
    )
    var incrementalResult: (diff: String?, commitLog: String?, wasForcePushed: Bool) = ("INC-DIFF", "abc1234 fix: purge", false)

    var prepareCalls: [PrepareCall] { lock.withLock { prepares } }
    var refreshCalls: [String] { lock.withLock { refreshes } }
    var incrementalCalls: [(path: String, previousSHA: String)] { lock.withLock { incrementals } }

    func prepareContext(
        for item: CollaborationItem,
        searchRoots: [String],
        extraLocalRepoPaths: [String],
        preferredLocalPath: String?,
        useIsolatedWorktree: Bool,
        previousReviewedSHA: String?,
        gitExecutablePath: String,
        environment: [String: String]
    ) async throws -> PreparedWorkspaceContext {
        lock.withLock {
            prepares.append(PrepareCall(
                item: item,
                preferredLocalPath: preferredLocalPath,
                useIsolatedWorktree: useIsolatedWorktree,
                previousReviewedSHA: previousReviewedSHA
            ))
        }
        return preparedContext
    }

    func refreshRemoteRefs(inRepositoryAt rootPath: String, code: CodeChangePayload, gitExecutablePath: String, environment: [String: String]) async {
        lock.withLock { refreshes.append(rootPath) }
    }

    func computeIncrementalChanges(
        inRepositoryAt rootPath: String,
        previousSHA: String,
        code: CodeChangePayload,
        gitExecutablePath: String,
        environment: [String: String]
    ) async -> (diff: String?, commitLog: String?, wasForcePushed: Bool) {
        lock.withLock { incrementals.append((rootPath, previousSHA)) }
        return incrementalResult
    }
}
