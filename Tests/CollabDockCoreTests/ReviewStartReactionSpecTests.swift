import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：Lody 会话派发成功后，CollabDock 在 PR 上加一个 👀（GitHub reaction `eyes`），告诉作者「已经在看了」。
///
/// - 由评论触发、且知道那条评论的 API 地址时，加在那条评论上；否则加在 PR 上（PR 即 issue）；
/// - 评论地址必须与配置的 GitHub API 同 scheme / host / port、不带账号密码 / query / fragment，且路径严格为
///   `<api 路径>/repos/<同一仓库>/(issues|pulls)/comments/<数字>`，否则一律退回 PR 本身——token 永远不会发往别的主机；
/// - 只在派发成功后加一次；失败、取消、开关关闭时不加；加 👀 失败不影响审查结果。
@Suite("SPEC — 👀 reaction when a review starts")
struct ReviewStartReactionSpecTests {
    static let api = URL(string: "https://api.github.com")!

    static func pr(repository: String = "acme/backend", number: Int = 7, commentURL: String? = nil) -> CollaborationItem {
        var item = CollaborationItem(
            id: "github:\(repository)#\(number):mention:c1",
            platform: .github,
            itemKind: .pullRequest,
            scope: repository,
            externalRef: "#\(number)",
            title: "PR \(number)",
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
            author: "alice",
            triggeredBy: "bob",
            triggerKind: commentURL == nil ? .reviewRequested : .mention,
            payload: .codeChange(CodeChangePayload(
                repository: repository, number: number, baseRef: "main", headRef: "feat/x",
                headSHA: "abc1234abc1234abc1234abc1234abc1234abc12", additions: 1, deletions: 0, changedFiles: 1
            ))
        )
        item.triggerCommentAPIURL = commentURL.flatMap(URL.init(string:))
        return item
    }

    // MARK: target selection

    @Test("Model defaults: new items carry no comment URL and are not auto-started")
    func modelDefaults() {
        let item = Self.pr()
        #expect(item.triggerCommentAPIURL == nil)
        #expect(item.wasAutoStarted == false)
    }

    @Test("Items persisted before this feature decode with no comment URL and not auto-started; both fields round-trip")
    func modelDecoding() throws {
        var item = Self.pr(commentURL: "https://api.github.com/repos/acme/backend/issues/comments/777")
        item.wasAutoStarted = true
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(CollaborationItem.self, from: data)
        #expect(decoded.triggerCommentAPIURL?.absoluteString == "https://api.github.com/repos/acme/backend/issues/comments/777")
        #expect(decoded.wasAutoStarted == true)

        var legacy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "triggerCommentAPIURL")
        legacy.removeValue(forKey: "wasAutoStarted")
        let old = try JSONDecoder().decode(CollaborationItem.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.triggerCommentAPIURL == nil)
        #expect(old.wasAutoStarted == false)
        #expect(old.id == item.id)
    }

    @Test("Without a comment, the reaction goes on the PR")
    func prTarget() {
        let url = GitHubReactionTarget.endpoint(for: Self.pr(), apiBaseURL: Self.api)
        #expect(url?.absoluteString == "https://api.github.com/repos/acme/backend/issues/7/reactions")
    }

    @Test("A trusted issue comment or PR review comment gets the reaction", arguments: [
        ("https://api.github.com/repos/acme/backend/issues/comments/777", "https://api.github.com/repos/acme/backend/issues/comments/777/reactions"),
        ("https://api.github.com/repos/acme/backend/pulls/comments/42", "https://api.github.com/repos/acme/backend/pulls/comments/42/reactions"),
        ("https://API.GitHub.com/repos/acme/backend/issues/comments/9", "https://API.GitHub.com/repos/acme/backend/issues/comments/9/reactions"),
    ])
    func trustedCommentTarget(comment: String, expected: String) {
        let url = GitHubReactionTarget.endpoint(for: Self.pr(commentURL: comment), apiBaseURL: Self.api)
        #expect(url?.absoluteString == expected)
    }

    @Test("GitHub Enterprise: both targets live under the configured API path")
    func enterpriseBase() {
        let ghe = URL(string: "https://ghe.acme.test/api/v3")!
        #expect(GitHubReactionTarget.endpoint(for: Self.pr(), apiBaseURL: ghe)?.absoluteString
                == "https://ghe.acme.test/api/v3/repos/acme/backend/issues/7/reactions")
        let comment = Self.pr(commentURL: "https://ghe.acme.test/api/v3/repos/acme/backend/issues/comments/5")
        #expect(GitHubReactionTarget.endpoint(for: comment, apiBaseURL: ghe)?.absoluteString
                == "https://ghe.acme.test/api/v3/repos/acme/backend/issues/comments/5/reactions")
        let missingAPIPath = Self.pr(commentURL: "https://ghe.acme.test/repos/acme/backend/issues/comments/5")
        #expect(GitHubReactionTarget.endpoint(for: missingAPIPath, apiBaseURL: ghe)?.absoluteString
                == "https://ghe.acme.test/api/v3/repos/acme/backend/issues/7/reactions")
    }

    @Test("SPEC (security): any untrusted comment URL falls back to the PR target on the API host", arguments: [
        "https://evil.test/repos/acme/backend/issues/comments/777",
        "https://api.github.com.evil.test/repos/acme/backend/issues/comments/777",
        "http://api.github.com/repos/acme/backend/issues/comments/777",
        "https://api.github.com:8443/repos/acme/backend/issues/comments/777",
        "https://user:pass@api.github.com/repos/acme/backend/issues/comments/777",
        "https://api.github.com/repos/acme/backend/issues/comments/777?redirect=https://evil.test",
        "https://api.github.com/repos/acme/backend/issues/comments/777#x",
        "https://api.github.com/repos/acme/backend/issues/comments/777/../../../../user",
        "https://api.github.com/repos/acme/backend/issues/comments/77a",
        "https://api.github.com/repos/acme/backend/issues/7",
        "https://api.github.com/repos/other/repo/issues/comments/777",
        "https://api.github.com/user/repos",
        "https://ghe.acme.test/api/v3/repos/acme/backend/issues/comments/5",
    ])
    func untrustedCommentFallsBack(comment: String) {
        let url = GitHubReactionTarget.endpoint(for: Self.pr(commentURL: comment), apiBaseURL: Self.api)
        #expect(url?.absoluteString == "https://api.github.com/repos/acme/backend/issues/7/reactions", "\(comment)")
    }

    @Test("Items without a pull request payload have no reaction target")
    func nonPRHasNoTarget() {
        let chat = CollaborationItem(
            id: "feishu:thread-1", platform: .feishu, itemKind: .conversation, scope: "#oncall", externalRef: "Thread",
            title: "help", url: URL(string: "https://example.com/thread/1")!, author: "bob", triggeredBy: "bob",
            triggerKind: .mention, payload: .conversation(ConversationPayload(channelName: "#oncall", threadID: "t1"))
        )
        #expect(GitHubReactionTarget.endpoint(for: chat, apiBaseURL: Self.api) == nil)
    }

    // MARK: connector

    @Test("GitHubConnector posts {\"content\":\"eyes\"} with the token to the PR reactions endpoint")
    func connectorPostsEyes() async throws {
        let transport = ReactionTransport(status: 201)
        let connector = GitHubConnector(transport: transport, tokenProvider: ReactionToken(value: "gho_placeholder"))

        try await connector.addReaction(.eyes, to: Self.pr())

        let req = try #require(transport.recorded.first)
        #expect(transport.recorded.count == 1)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.github.com/repos/acme/backend/issues/7/reactions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer gho_placeholder")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        let body = try #require(req.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["content": "eyes"])
    }

    @Test("An existing reaction (200) is fine; the reaction lands on the triggering comment when trusted")
    func connectorCommentTarget() async throws {
        let transport = ReactionTransport(status: 200)
        let connector = GitHubConnector(transport: transport, tokenProvider: ReactionToken(value: "gho_placeholder"))

        try await connector.addReaction(.eyes, to: Self.pr(commentURL: "https://api.github.com/repos/acme/backend/issues/comments/777"))

        #expect(transport.recorded.map { $0.url?.absoluteString } == ["https://api.github.com/repos/acme/backend/issues/comments/777/reactions"])
    }

    @Test("SPEC (security): a hostile comment URL never receives the token")
    func connectorNeverPostsElsewhere() async throws {
        let transport = ReactionTransport(status: 201)
        let connector = GitHubConnector(transport: transport, tokenProvider: ReactionToken(value: "gho_placeholder"))

        try await connector.addReaction(.eyes, to: Self.pr(commentURL: "https://evil.test/repos/acme/backend/issues/comments/777"))

        #expect(transport.recorded.allSatisfy { $0.url?.host == "api.github.com" })
        #expect(transport.recorded.map { $0.url?.path } == ["/repos/acme/backend/issues/7/reactions"])
    }

    @Test("Errors surface to the caller: forbidden, not found, or no token", arguments: [403, 404, 500])
    func connectorErrors(status: Int) async {
        let connector = GitHubConnector(transport: ReactionTransport(status: status), tokenProvider: ReactionToken(value: "gho_placeholder"))
        await #expect(throws: (any Error).self) { try await connector.addReaction(.eyes, to: Self.pr()) }
    }

    @Test("Without a token nothing is sent and the call fails")
    func connectorWithoutToken() async {
        let transport = ReactionTransport(status: 201)
        let connector = GitHubConnector(transport: transport, tokenProvider: ReactionToken(value: nil))
        await #expect(throws: (any Error).self) { try await connector.addReaction(.eyes, to: Self.pr()) }
        #expect(transport.recorded.isEmpty)
    }

    // MARK: connector — remembering the triggering comment

    @Test("A mention from notifications remembers the comment's API URL; a review request remembers none")
    func pollRemembersNotificationComment() async throws {
        let transport = ReactionTransport(status: 404, routes: [
            "GET /notifications": (200, """
            [{"id": "n1", "reason": "mention", "updated_at": "2026-11-26T10:15:00Z",
              "subject": {"title": "feat: add cache", "url": "https://api.github.com/repos/acme/backend/pulls/482",
                          "latest_comment_url": "https://api.github.com/repos/acme/backend/issues/comments/777", "type": "PullRequest"},
              "repository": {"full_name": "acme/backend"}},
             {"id": "n2", "reason": "review_requested", "updated_at": "2026-11-26T10:16:00Z",
              "subject": {"title": "fix: layout", "url": "https://api.github.com/repos/acme/backend/pulls/483",
                          "latest_comment_url": null, "type": "PullRequest"},
              "repository": {"full_name": "acme/backend"}}]
            """),
            "GET /repos/acme/backend/pulls/482": (200, Self.prJSON(number: 482, head: "head482")),
            "GET /repos/acme/backend/pulls/483": (200, Self.prJSON(number: 483, head: "head483")),
            "GET /repos/acme/backend/issues/comments/777": (200, #"{"id": 777, "body": "@dev please review", "user": {"login": "bob"}}"#),
        ])
        let connector = GitHubConnector(
            transport: transport, tokenProvider: ReactionToken(value: "gho_placeholder"),
            includeReviewRequestedSearch: false, includeMentionsSearchFallback: false
        )

        let batch = try await connector.poll(cursor: nil)

        let mention = try #require(batch.candidates.first { $0.item.externalRef == "#482" })
        #expect(mention.item.triggerCommentAPIURL?.absoluteString == "https://api.github.com/repos/acme/backend/issues/comments/777")
        let request = try #require(batch.candidates.first { $0.item.externalRef == "#483" })
        #expect(request.item.triggerCommentAPIURL == nil)
    }

    @Test("A mention found through Search remembers the latest comment's API URL")
    func pollRemembersSearchComment() async throws {
        let transport = ReactionTransport(status: 404, routes: [
            "GET /notifications": (403, #"{"message": "Requires notifications scope"}"#),
            "GET /search/issues": (200, """
            {"items": [{"number": 191, "title": "fix: layout", "body": "",
                        "repository_url": "https://api.github.com/repos/acme/web",
                        "comments_url": "https://api.github.com/repos/acme/web/issues/191/comments",
                        "pull_request": {"url": "https://api.github.com/repos/acme/web/pulls/191"}}]}
            """),
            "GET /repos/acme/web/pulls/191": (200, Self.prJSON(number: 191, head: "head191", repo: "acme/web")),
            "GET /repos/acme/web/issues/191/comments": (200, #"[{"id": 9000, "body": "older", "user": {"login": "carol"}}, {"id": 9001, "body": "@dev review please", "user": {"login": "carol"}}]"#),
        ])
        let connector = GitHubConnector(
            transport: transport, tokenProvider: ReactionToken(value: "gho_placeholder"),
            includeReviewRequestedSearch: false, includeMentionsSearchFallback: true
        )

        let batch = try await connector.poll(cursor: nil)

        let mention = try #require(batch.candidates.first { $0.item.triggerKind == .mention })
        #expect(mention.item.triggerCommentAPIURL?.absoluteString == "https://api.github.com/repos/acme/web/issues/comments/9001")
    }

    static func prJSON(number: Int, head: String, repo: String = "acme/backend") -> String {
        """
        {"number": \(number), "title": "PR \(number)", "html_url": "https://github.com/\(repo)/pull/\(number)",
         "draft": false, "additions": 1, "deletions": 0, "changed_files": 1, "updated_at": "2026-11-26T10:15:00Z",
         "user": {"login": "alice"}, "base": {"ref": "main", "sha": "b0"}, "head": {"ref": "feat/x", "sha": "\(head)"}}
        """
    }

    // MARK: service

    private func dispatched() -> AgentRunResult {
        AgentRunResult(
            output: nil,
            sessionHandle: AgentSessionHandle(engine: .lody, sessionID: "lody-9", workspacePath: "/tmp/collabdock-lody-worktree", launchMode: .nativeBackgroundSession),
            rawOutputText: "",
            wasBackgroundDispatched: true
        )
    }

    private func request(_ item: CollaborationItem, ticket: ExecutionRunTicket? = nil, react: Bool) -> ReviewExecutionRequest {
        ReviewExecutionRequest(
            item: item,
            plan: ExecutionPlan(engine: .lody, model: "default", launchMode: .nativeBackgroundSession),
            preset: TaskPreset.defaults[0],
            ticket: ticket ?? ExecutionRunTicket(itemID: item.id),
            addStartReaction: react
        )
    }

    @Test("After a successful dispatch the service adds 👀 exactly once, on the dispatched item")
    func serviceReactsOnSuccess() async throws {
        let backend = FakeBackend(context: Fixtures.workspace(path: "/tmp/collabdock-lody-worktree"))
        backend.result = dispatched()
        let reactor = RecordingReactor()
        let service = ReviewExecutionService(backend: backend, store: InMemoryTaskStore(), reactor: reactor)
        let item = Fixtures.prItem(status: .pendingConfirmation)

        let outcome = try await service.execute(request(item, react: true))

        guard case .backgroundDispatched = outcome else { Issue.record("expected .backgroundDispatched, got \(outcome)"); return }
        #expect(reactor.calls.map(\.itemID) == [item.id])
        #expect(reactor.calls.map(\.content) == [.eyes])
    }

    @Test("The reaction switch off: nothing is added")
    func serviceRespectsSwitch() async throws {
        let backend = FakeBackend(context: Fixtures.workspace(path: "/tmp/collabdock-lody-worktree"))
        backend.result = dispatched()
        let reactor = RecordingReactor()
        let service = ReviewExecutionService(backend: backend, store: InMemoryTaskStore(), reactor: reactor)

        _ = try await service.execute(request(Fixtures.prItem(status: .pendingConfirmation), react: false))

        #expect(reactor.calls.isEmpty)
    }

    @Test("A failed dispatch adds nothing")
    func serviceNoReactionOnFailure() async {
        let backend = FakeBackend(context: Fixtures.workspace(path: "/tmp/collabdock-lody-worktree"))
        backend.executeError = AgentRunnerError.processFailed(exitCode: 1, stderr: "lody login expired")
        let reactor = RecordingReactor()
        let service = ReviewExecutionService(backend: backend, store: InMemoryTaskStore(), reactor: reactor)

        await #expect(throws: (any Error).self) {
            _ = try await service.execute(request(Fixtures.prItem(status: .pendingConfirmation), react: true))
        }
        #expect(reactor.calls.isEmpty)
    }

    @Test("A cancelled run adds nothing")
    func serviceNoReactionOnCancel() async throws {
        let backend = FakeBackend(context: Fixtures.workspace(path: "/tmp/collabdock-lody-worktree"))
        backend.result = dispatched()
        let item = Fixtures.prItem(status: .pendingConfirmation)
        let ticket = ExecutionRunTicket(itemID: item.id)
        backend.onExecute = { _ in ticket.cancel() }
        let reactor = RecordingReactor()
        let service = ReviewExecutionService(backend: backend, store: InMemoryTaskStore(), reactor: reactor)

        let outcome = try await service.execute(request(item, ticket: ticket, react: true))

        guard case .cancelled = outcome else { Issue.record("expected .cancelled, got \(outcome)"); return }
        #expect(reactor.calls.isEmpty)
    }

    @Test("A failing reaction never changes the review outcome or the saved item")
    func reactionFailureIsIgnored() async throws {
        let backend = FakeBackend(context: Fixtures.workspace(path: "/tmp/collabdock-lody-worktree"))
        backend.result = dispatched()
        let reactor = RecordingReactor()
        reactor.error = GitHubConnectorError.httpError(statusCode: 403, message: "Resource not accessible by integration")
        let store = InMemoryTaskStore()
        let service = ReviewExecutionService(backend: backend, store: store, reactor: reactor)
        let item = Fixtures.prItem(status: .pendingConfirmation)

        let outcome = try await service.execute(request(item, react: true))

        guard case .backgroundDispatched(let tracked, _, _, _) = outcome else { Issue.record("expected .backgroundDispatched, got \(outcome)"); return }
        #expect(tracked.status == .draftReady)
        #expect(tracked.errorMessage == nil)
        #expect(reactor.calls.count == 1)
        #expect(await store.item(item.id)?.status == .draftReady)
    }

    @Test("Re-reviews that continue the Lody session add 👀 too")
    func reReviewReacts() async throws {
        let backend = FakeBackend(context: Fixtures.workspace(path: "/tmp/collabdock-lody-worktree"))
        backend.result = dispatched()
        let reactor = RecordingReactor()
        let service = ReviewExecutionService(backend: backend, store: InMemoryTaskStore(), reactor: reactor)
        var item = Fixtures.prItem(status: .pendingConfirmation)
        let previous = PreviousReviewContext(
            previousItemID: "r1", reviewedHeadSHA: "0000000000000000000000000000000000000000",
            reviewedAt: Date(timeIntervalSince1970: 1_800_000_000), engine: .lody, sessionID: "lody-1", reviewRound: 1
        )
        item.previousReview = previous
        item.reviewRound = 2

        _ = try await service.execute(ReviewExecutionRequest(
            item: item,
            plan: ExecutionPlan(engine: .lody, model: "default", launchMode: .nativeBackgroundSession,
                                continuityMode: .continueSessionIncremental, previousReview: previous),
            preset: TaskPreset.defaults[0],
            ticket: ExecutionRunTicket(itemID: item.id),
            addStartReaction: true
        ))

        #expect(reactor.calls.map(\.itemID) == [item.id])
    }
}

// MARK: - Fakes

final class RecordingReactor: PullRequestReacting, @unchecked Sendable {
    struct Call: Equatable {
        let itemID: String
        let content: GitHubReactionContent
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var _error: Error?

    var calls: [Call] { lock.withLock { recorded } }
    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    func addReaction(_ content: GitHubReactionContent, to item: CollaborationItem) async throws {
        let failure = lock.withLock { () -> Error? in
            recorded.append(Call(itemID: item.id, content: content))
            return _error
        }
        if let failure { throw failure }
    }
}

private struct ReactionToken: GitHubTokenProvider {
    let value: String?
    func fetchToken() async -> String? { value }
}

/// 按「方法 + 路径」路由，记录完整请求（含 body）；未命中的路由返回构造时给定的状态码
private final class ReactionTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private let fallbackStatus: Int
    private let routes: [String: (Int, String)]

    init(status: Int, routes: [String: (Int, String)] = [:]) {
        self.fallbackStatus = status
        self.routes = routes
    }

    var recorded: [URLRequest] { lock.withLock { requests.filter { $0.httpMethod == "POST" } } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let (status, body) = routes[key] ?? (fallbackStatus, fallbackStatus < 300 ? #"{"id": 1, "content": "eyes"}"# : #"{"message": "nope"}"#)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
