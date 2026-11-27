import Foundation
@testable import CollabDockCore

/// 一个完整的「有人请我 Review PR」场景：真实 git 仓库 + 假 GitHub + 收件箱条目。
///
/// 仓库内容（PR 分支相对 main 新增第 4、5 行）：
/// ```
/// 1  struct Cache {
/// 2      var storage: [String: String] = [:]
/// 3      func get(_ key: String) -> String? { storage[key] }
/// 4      static let ttl = 60          // + PR
/// 5      func purge() { }             // + PR
/// 6  }
/// ```
struct PRScenario {
    static let repository = "acme/backend"
    static let number = 7
    static let headRef = "feat/cache"
    static let filePath = "Sources/Cache.swift"
    static let reviewer = "reviewer"
    static let token = "gho_e2e_host_only_token"

    let sandbox: GitSandbox
    let github = FakeGitHub()
    let headSHA: String

    static let baseFile = """
    struct Cache {
        var storage: [String: String] = [:]
        func get(_ key: String) -> String? { storage[key] }
    }

    """

    static let prFile = """
    struct Cache {
        var storage: [String: String] = [:]
        func get(_ key: String) -> String? { storage[key] }
        static let ttl = 60
        func purge() { }
    }

    """

    /// - Parameter prTitle: PR 标题（可注入恶意文本测试 Prompt 隔离）
    static func make(prTitle: String = "feat: add ttl and purge") async throws -> PRScenario {
        let sb = try await GitSandbox()
        try sb.write(filePath, baseFile)
        try await sb.commitAll("init")
        try await sb.git(["-C", sb.userRepo.path, "push", "-q", "-u", "origin", "main"])

        try await sb.git(["-C", sb.userRepo.path, "checkout", "-q", "-b", headRef])
        try sb.write(filePath, prFile)
        let head = try await sb.commitAll("feat: add ttl and purge")
        try await sb.publishPullRequest(number: number, branch: headRef)

        // 用户回到自己的 main 分支继续干活，并留有未提交的改动
        try await sb.git(["-C", sb.userRepo.path, "checkout", "-q", "main"])
        try sb.write("WIP.txt", "my uncommitted work\n")

        let scenario = PRScenario(sandbox: sb, headSHA: head)
        scenario.stubGitHub(headSHA: head, title: prTitle)
        return scenario
    }

    func stubGitHub(headSHA: String, title: String) {
        let titleJSON = String(data: try! JSONEncoder().encode(title), encoding: .utf8)!
        github.on(
            "GET", "/notifications",
            json: """
            [{
              "id": "n-7",
              "reason": "review_requested",
              "updated_at": "2026-11-26T10:15:00Z",
              "subject": {
                "title": \(titleJSON),
                "url": "https://api.github.com/repos/\(Self.repository)/pulls/\(Self.number)",
                "latest_comment_url": null,
                "type": "PullRequest"
              },
              "repository": { "full_name": "\(Self.repository)" }
            }]
            """,
            headers: ["Last-Modified": "Thu, 26 Nov 2026 10:15:00 GMT", "X-Poll-Interval": "60"]
        )
        github.on(
            "GET", "/repos/\(Self.repository)/pulls/\(Self.number)",
            json: """
            {
              "number": \(Self.number),
              "title": \(titleJSON),
              "html_url": "https://github.com/\(Self.repository)/pull/\(Self.number)",
              "draft": false,
              "additions": 2,
              "deletions": 0,
              "changed_files": 1,
              "updated_at": "2026-11-26T10:15:00Z",
              "user": { "login": "alice" },
              "base": { "ref": "main", "sha": "0000000000000000000000000000000000000000" },
              "head": { "ref": "\(Self.headRef)", "sha": "\(headSHA)" }
            }
            """
        )
        github.on(
            "POST", "/repos/\(Self.repository)/pulls/\(Self.number)/reviews",
            json: #"{"id": 1001, "state": "PENDING"}"#
        )
    }

    var connector: GitHubConnector {
        GitHubConnector(
            transport: github,
            tokenProvider: StaticTokenProvider(token: Self.token),
            includeReviewRequestedSearch: false,
            includeMentionsSearchFallback: false
        )
    }

    var worktreeManager: WorktreeManager {
        WorktreeManager(cacheRootURL: sandbox.cacheRoot)
    }

    func prepare(
        _ item: CollaborationItem,
        previousReviewedSHA: String? = nil
    ) async throws -> PreparedWorkspaceContext {
        try await worktreeManager.prepareContext(
            for: item,
            searchRoots: [],
            preferredLocalPath: sandbox.userRepo.path,
            useIsolatedWorktree: true,
            previousReviewedSHA: previousReviewedSHA,
            gitExecutablePath: sandbox.gitPath,
            environment: sandbox.env
        )
    }

    /// PR 作者在自己机器上（另一个 clone）推送修复提交；`rewriteHistory` 时模拟 rebase + force-push
    @discardableResult
    func authorPushes(content: String, message: String, rewriteHistory: Bool = false) async throws -> String {
        let author = sandbox.root.appendingPathComponent("work/author-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try await sandbox.git(["clone", "-q", sandbox.origin.path, author.path])
        try await sandbox.git(["-C", author.path, "checkout", "-q", rewriteHistory ? "main" : Self.headRef])
        if rewriteHistory {
            try await sandbox.git(["-C", author.path, "checkout", "-q", "-B", Self.headRef])
        }
        try content.write(to: author.appendingPathComponent(Self.filePath), atomically: true, encoding: .utf8)
        try await sandbox.git(["-C", author.path, "commit", "-q", "-am", message])
        try await sandbox.git([
            "-C", author.path, "push", "-q", "--force", "origin",
            "HEAD:refs/heads/\(Self.headRef)", "HEAD:refs/pull/\(Self.number)/head"
        ])
        return try await sandbox.git(["-C", author.path, "rev-parse", "HEAD"])
    }

    func item(headSHA: String, previousReview: PreviousReviewContext? = nil, title: String = "feat: add ttl and purge") -> CollaborationItem {
        CollaborationItem(
            id: "github:\(Self.repository)#\(Self.number):reviewRequested:\(headSHA)",
            platform: .github,
            itemKind: .pullRequest,
            scope: Self.repository,
            externalRef: "#\(Self.number)",
            title: title,
            url: URL(string: "https://github.com/\(Self.repository)/pull/\(Self.number)")!,
            author: "alice",
            triggeredBy: "alice",
            triggerKind: .reviewRequested,
            payload: .codeChange(
                CodeChangePayload(
                    repository: Self.repository,
                    number: Self.number,
                    baseRef: "main",
                    headRef: Self.headRef,
                    headSHA: headSHA,
                    additions: 2,
                    deletions: 0,
                    changedFiles: 1
                )
            ),
            previousReview: previousReview,
            reviewRound: previousReview == nil ? 1 : previousReview!.reviewRound + 1
        )
    }
}

/// 模型返回的结构化审查：一条落在 diff 内（第 5 行），一条越界（第 250 行，应降级进总结）
enum SampleReview {
    static let inDiffLine = 5
    static let json = #"{"summary":"Adds a TTL constant; purge() is a no-op.","recommendedVerdict":"COMMENT","comments":[{"path":"Sources/Cache.swift","line":5,"side":"RIGHT","severity":"warning","title":"purge() does nothing","body":"Clear the storage here.","suggestion":"    mutating func purge() { storage.removeAll() }"},{"path":"Sources/Cache.swift","line":250,"side":"RIGHT","severity":"nit","title":"Out-of-diff note","body":"Should be folded into the review summary."}]}"#
}

/// 线程安全的进度收集器
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
