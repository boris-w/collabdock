import Foundation
import Testing
@testable import CollabDockCore

private struct Token: GitHubTokenProvider {
    let value: String?
    func fetchToken() async -> String? { value }
}

/// 按「方法 + 路径」路由的假 GitHub，记录请求
private final class RoutedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private let routes: [String: (Int, String)]

    init(_ routes: [String: (Int, String)]) { self.routes = routes }

    var recorded: [URLRequest] { lock.withLock { requests } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        lock.withLock { requests.append(request) }
        let (status, body) = routes[key] ?? (404, #"{"message":"Not Found"}"#)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let prJSON = """
{
  "number": 7, "title": "feat: add ttl", "html_url": "https://github.com/acme/backend/pull/7",
  "draft": false, "additions": 2, "deletions": 0, "changed_files": 1, "updated_at": "2026-11-26T10:15:00Z",
  "user": { "login": "alice" },
  "base": { "ref": "main", "sha": "b0" },
  "head": { "ref": "feat/cache", "sha": "abcdef0123456789abcdef0123456789abcdef01" }
}
"""

@Suite("GitHubConnector — manual PR import, batched PR status query, diff fetch on delivery")
struct GitHubConnectorFetchTests {
    // MARK: fetchPullRequest

    @Test("Importing by URL or owner/repo#number fetches the PR and builds a pending review-request item", arguments: [
        "https://github.com/acme/backend/pull/7",
        "https://github.com/acme/backend/pull/7/files",
        "acme/backend#7"
    ])
    func importPullRequest(reference: String) async throws {
        let transport = RoutedTransport(["GET /repos/acme/backend/pulls/7": (200, prJSON)])
        let connector = GitHubConnector(transport: transport, tokenProvider: Token(value: "gho_placeholder"))

        let item = try await connector.fetchPullRequest(reference: reference)

        #expect(item.platform == .github)
        #expect(item.scope == "acme/backend")
        #expect(item.externalRef == "#7")
        #expect(item.status == .pendingConfirmation)
        #expect(item.triggerKind == .reviewRequested)
        guard case .codeChange(let code) = item.payload else { Issue.record("expected code change payload"); return }
        #expect(code.headSHA == "abcdef0123456789abcdef0123456789abcdef01")
        #expect(code.headRef == "feat/cache")
        #expect(transport.recorded.first?.value(forHTTPHeaderField: "Authorization") == "Bearer gho_placeholder")
    }

    @Test("Import errors: invalid reference (400), missing token, unknown PR (404)")
    func importErrors() async throws {
        let transport = RoutedTransport([:])
        let connector = GitHubConnector(transport: transport, tokenProvider: Token(value: "gho_placeholder"))

        await #expect(throws: GitHubConnectorError.self) { _ = try await connector.fetchPullRequest(reference: "not a pr") }
        #expect(transport.recorded.isEmpty, "invalid references must not hit the network")

        await #expect(throws: GitHubConnectorError.missingToken) {
            _ = try await GitHubConnector(transport: transport, tokenProvider: Token(value: nil)).fetchPullRequest(reference: "acme/backend#7")
        }

        do {
            _ = try await connector.fetchPullRequest(reference: "acme/backend#999")
            Issue.record("expected 404")
        } catch let GitHubConnectorError.httpError(code, _) {
            #expect(code == 404)
        }
    }

    // MARK: PR status (GraphQL)

    private static let statusResponse = """
    {"data":{"viewer":{"login":"me"},
     "pr0":{"pullRequest":{"state":"MERGED","merged":true,"headRefOid":"abcdef0123456789abcdef0123456789abcdef01","reviews":{"nodes":[]}}},
     "pr1":{"pullRequest":{"state":"OPEN","merged":false,"headRefOid":"1234567","reviews":{"nodes":[{"state":"APPROVED","submittedAt":"2026-11-27T03:50:48Z","author":{"login":"me"},"commit":{"oid":"1234567"}}]}}}}}
    """

    private func graphQLQuery(_ request: URLRequest?) -> String {
        guard let body = request?.httpBody,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
        return obj["query"] as? String ?? ""
    }

    @Test("PR status: one GraphQL request for all targets, parsed into snapshots keyed by owner/name#number")
    func prStatusBatch() async throws {
        let transport = RoutedTransport(["POST /graphql": (200, Self.statusResponse)])
        let connector = GitHubConnector(transport: transport, tokenProvider: Token(value: "gho_placeholder"))

        let result = try await connector.fetchPRStatusSnapshots(targets: [
            PRStateReconciler.Target(repository: "acme/backend", number: 7),
            PRStateReconciler.Target(repository: "Acme/Web", number: 12),
            PRStateReconciler.Target(repository: "acme/backend", number: 7) // duplicate
        ])

        #expect(transport.recorded.count == 1)
        let query = graphQLQuery(transport.recorded.first)
        #expect(query.contains(#"pr0: repository(owner: "acme", name: "backend")"#))
        #expect(query.contains(#"pr1: repository(owner: "Acme", name: "Web")"#))
        #expect(!query.contains("pr2:"), "duplicates are queried once")
        #expect(result.viewerLogin == "me")
        #expect(result.snapshots["acme/backend#7"]?.merged == true)
        #expect(result.snapshots["acme/web#12"]?.reviews.first?.state == "APPROVED")
    }

    @Test("Security: repository names that could inject GraphQL are dropped before the query is built")
    func prStatusRejectsInjection() async throws {
        let transport = RoutedTransport(["POST /graphql": (200, #"{"data":{"viewer":{"login":"me"}}}"#)])
        let connector = GitHubConnector(transport: transport, tokenProvider: Token(value: "gho_placeholder"))

        _ = try await connector.fetchPRStatusSnapshots(targets: [
            PRStateReconciler.Target(repository: #"acme") { viewer { login } } #"#, number: 1),
            PRStateReconciler.Target(repository: "acme/back end", number: 2),
            PRStateReconciler.Target(repository: "acme/backend/extra", number: 3),
            PRStateReconciler.Target(repository: "acme/backend", number: 0),
            PRStateReconciler.Target(repository: "acme/safe-repo.v2", number: 4)
        ])

        let query = graphQLQuery(transport.recorded.first)
        #expect(query.contains(#"repository(owner: "acme", name: "safe-repo.v2")"#))
        #expect(query.components(separatedBy: "repository(").count - 1 == 1, "only the valid target is queried")
        #expect(!query.contains("back end") && !query.contains("extra"))
        #expect(!query.contains(#"acme") { viewer"#), "the injected fragment must never reach the query")
    }

    @Test("PR status: at most 25 PRs per request")
    func prStatusCapsBatchSize() async throws {
        let transport = RoutedTransport(["POST /graphql": (200, #"{"data":{"viewer":{"login":"me"}}}"#)])
        let connector = GitHubConnector(transport: transport, tokenProvider: Token(value: "gho_placeholder"))

        _ = try await connector.fetchPRStatusSnapshots(targets: (1...30).map { PRStateReconciler.Target(repository: "acme/backend", number: $0) })

        let query = graphQLQuery(transport.recorded.first)
        #expect(query.contains("pr24:"))
        #expect(!query.contains("pr25:"))
    }

    @Test("PR status: no targets, no valid targets or no token → no request; HTTP errors → empty result")
    func prStatusNoopCases() async throws {
        let transport = RoutedTransport(["POST /graphql": (500, "oops")])
        let connector = GitHubConnector(transport: transport, tokenProvider: Token(value: "gho_placeholder"))

        #expect(try await connector.fetchPRStatusSnapshots(targets: []).snapshots.isEmpty)
        #expect(try await connector.fetchPRStatusSnapshots(targets: [PRStateReconciler.Target(repository: "bad name", number: 1)]).snapshots.isEmpty)
        let tokenless = GitHubConnector(transport: transport, tokenProvider: Token(value: nil))
        #expect(try await tokenless.fetchPRStatusSnapshots(targets: [PRStateReconciler.Target(repository: "acme/backend", number: 7)]).snapshots.isEmpty)
        #expect(transport.recorded.isEmpty)

        let failed = try await connector.fetchPRStatusSnapshots(targets: [PRStateReconciler.Target(repository: "acme/backend", number: 7)])
        #expect(failed.snapshots.isEmpty)
        #expect(failed.viewerLogin == nil)
    }
}
