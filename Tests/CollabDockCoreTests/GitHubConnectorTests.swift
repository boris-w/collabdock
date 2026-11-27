import Foundation
import Testing
@testable import CollabDockCore

private struct MockTokenProvider: GitHubTokenProvider {
    let token: String?
    func fetchToken() async -> String? { token }
}

private final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    var handler: (URLRequest) -> (Data, HTTPURLResponse)

    init(handler: @escaping (URLRequest) -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        handler(request)
    }

    static func response(url: URL, statusCode: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

@Suite("GitHubConnector Tests [REQ-002][ADR-002][TASK-005]")
struct GitHubConnectorTests {
    @Test("Handles 304 Not Modified without consuming rate limit and respects X-Poll-Interval")
    func conditionalPolling304() async throws {
        var seenIfModifiedSince: String?
        let transport = MockHTTPTransport { req in
            seenIfModifiedSince = req.value(forHTTPHeaderField: "If-Modified-Since")
            return (
                Data(),
                MockHTTPTransport.response(
                    url: req.url!,
                    statusCode: 304,
                    headers: ["X-Poll-Interval": "90", "Last-Modified": "Thu, 26 Nov 2026 10:00:00 GMT"]
                )
            )
        }

        let connector = GitHubConnector(
            transport: transport,
            tokenProvider: MockTokenProvider(token: "gho_test"),
            includeReviewRequestedSearch: false,
            includeMentionsSearchFallback: false
        )

        let cursor = SyncCursor(value: "Thu, 26 Nov 2026 09:59:00 GMT")
        let batch = try await connector.poll(cursor: cursor)

        #expect(seenIfModifiedSince == "Thu, 26 Nov 2026 09:59:00 GMT")
        #expect(batch.wasNotModified == true)
        #expect(batch.candidates.isEmpty)
        #expect(batch.suggestedPollIntervalSeconds == 90)
        #expect(batch.nextCursor?.value == "Thu, 26 Nov 2026 10:00:00 GMT")
    }

    @Test("Hydrates PR metadata and comment body from 200 notifications")
    func notifications200Hydration() async throws {
        let transport = MockHTTPTransport { req in
            let urlStr = req.url!.absoluteString
            if urlStr.hasSuffix("/notifications") {
                let json = """
                [{
                  "id": "n1",
                  "reason": "mention",
                  "updated_at": "2026-11-26T10:15:00Z",
                  "subject": {
                    "title": "feat: add cache",
                    "url": "https://api.github.com/repos/acme/backend/pulls/482",
                    "latest_comment_url": "https://api.github.com/repos/acme/backend/issues/comments/777",
                    "type": "PullRequest"
                  },
                  "repository": { "full_name": "acme/backend" }
                }]
                """
                return (
                    Data(json.utf8),
                    MockHTTPTransport.response(url: req.url!, statusCode: 200, headers: ["X-Poll-Interval": "60", "Last-Modified": "Thu, 26 Nov 2026 10:15:00 GMT"])
                )
            } else if urlStr.contains("/pulls/482") {
                let json = """
                {
                  "number": 482,
                  "title": "feat: add cache",
                  "html_url": "https://github.com/acme/backend/pull/482",
                  "draft": false,
                  "additions": 120,
                  "deletions": 14,
                  "changed_files": 4,
                  "updated_at": "2026-11-26T10:15:00Z",
                  "user": { "login": "alice" },
                  "base": { "ref": "main", "sha": "base123" },
                  "head": { "ref": "feat/cache", "sha": "head456" }
                }
                """
                return (Data(json.utf8), MockHTTPTransport.response(url: req.url!, statusCode: 200))
            } else if urlStr.contains("/comments/777") {
                let json = """
                {
                  "id": 777,
                  "body": "@boris-w 帮忙 review --model opus",
                  "user": { "login": "bob" }
                }
                """
                return (Data(json.utf8), MockHTTPTransport.response(url: req.url!, statusCode: 200))
            }
            return (Data(), MockHTTPTransport.response(url: req.url!, statusCode: 404))
        }

        let connector = GitHubConnector(
            transport: transport,
            tokenProvider: MockTokenProvider(token: "gho_test"),
            includeReviewRequestedSearch: false,
            includeMentionsSearchFallback: false
        )

        let batch = try await connector.poll(cursor: nil)
        #expect(batch.candidates.count == 1)
        let candidate = try #require(batch.candidates.first)
        #expect(candidate.item.scope == "acme/backend")
        #expect(candidate.item.externalRef == "#482")
        #expect(candidate.item.triggeredBy == "bob")
        #expect(candidate.item.triggerBody == "@boris-w 帮忙 review --model opus")
        if case .codeChange(let code) = candidate.item.payload {
            #expect(code.additions == 120)
            #expect(code.deletions == 14)
        } else {
            Issue.record("Expected .codeChange payload")
        }
    }

    @Test("Falls back smoothly to Search API when notifications endpoint returns 403 missing scope")
    func notifications403FallsBackToSearch() async throws {
        let transport = MockHTTPTransport { req in
            let urlStr = req.url!.absoluteString
            if urlStr.hasSuffix("/notifications") {
                return (Data("{\"message\":\"Requires notifications scope\"}".utf8), MockHTTPTransport.response(url: req.url!, statusCode: 403))
            } else if urlStr.contains("/search/issues") && urlStr.contains("review-requested") {
                let json = """
                {
                  "items": [{
                    "number": 191,
                    "title": "fix: layout",
                    "body": "",
                    "repository_url": "https://api.github.com/repos/acme/web",
                    "comments_url": "https://api.github.com/repos/acme/web/issues/191/comments",
                    "pull_request": { "url": "https://api.github.com/repos/acme/web/pulls/191" }
                  }]
                }
                """
                return (Data(json.utf8), MockHTTPTransport.response(url: req.url!, statusCode: 200))
            } else if urlStr.contains("/search/issues") && urlStr.contains("mentions") {
                return (Data("{\"items\":[]}".utf8), MockHTTPTransport.response(url: req.url!, statusCode: 200))
            } else if urlStr.contains("/pulls/191") {
                let json = """
                {
                  "number": 191,
                  "title": "fix: layout",
                  "html_url": "https://github.com/acme/web/pull/191",
                  "draft": false,
                  "additions": 20,
                  "deletions": 5,
                  "changed_files": 2,
                  "updated_at": "2026-11-26T10:15:00Z",
                  "user": { "login": "charlie" },
                  "base": { "ref": "main", "sha": "b1" },
                  "head": { "ref": "fix/layout", "sha": "h1" }
                }
                """
                return (Data(json.utf8), MockHTTPTransport.response(url: req.url!, statusCode: 200))
            }
            return (Data(), MockHTTPTransport.response(url: req.url!, statusCode: 404))
        }

        let connector = GitHubConnector(
            transport: transport,
            tokenProvider: MockTokenProvider(token: "gho_repo_only")
        )

        let batch = try await connector.poll(cursor: nil)
        #expect(batch.diagnosticMessage?.contains("gh auth refresh -s notifications") == true)
        #expect(batch.candidates.count == 1)
        #expect(batch.candidates.first?.item.triggerKind == .reviewRequested)
        #expect(batch.candidates.first?.item.scope == "acme/web")
    }

    @Test("304 fast path skips Search calls completely when reconcileReviewRequestedNow is false")
    func zeroQuota304FastPathSkipsSearch() async throws {
        var callCount = 0
        let transport = MockHTTPTransport { req in
            callCount += 1
            return (
                Data(),
                MockHTTPTransport.response(
                    url: req.url!,
                    statusCode: 304,
                    headers: [
                        "X-Poll-Interval": "60",
                        "X-RateLimit-Limit": "5000",
                        "X-RateLimit-Remaining": "4999"
                    ]
                )
            )
        }

        let connector = GitHubConnector(
            transport: transport,
            tokenProvider: MockTokenProvider(token: "gho_with_notif"),
            includeReviewRequestedSearch: true,
            knownNotificationsScope: true,
            reconcileReviewRequestedNow: false
        )

        let batch = try await connector.poll(cursor: SyncCursor(value: "Thu, 26 Nov 2026 10:00:00 GMT"))
        #expect(callCount == 1)
        #expect(batch.wasNotModified == true)
        #expect(batch.rateLimit?.remaining == 4999)
    }

    @Test("Skips PR detail hydration when updated_at fingerprint is unchanged")
    func fingerprintSkipsUnchangedPRHydration() async throws {
        var detailFetchCount = 0
        let transport = MockHTTPTransport { req in
            let urlStr = req.url!.absoluteString
            if urlStr.contains("/search/issues") {
                let json = """
                {
                  "items": [{
                    "number": 191,
                    "title": "fix: layout",
                    "updated_at": "2026-11-26T10:15:00Z",
                    "repository_url": "https://api.github.com/repos/acme/web",
                    "comments_url": "https://api.github.com/repos/acme/web/issues/191/comments",
                    "pull_request": { "url": "https://api.github.com/repos/acme/web/pulls/191" }
                  }]
                }
                """
                return (Data(json.utf8), MockHTTPTransport.response(url: req.url!, statusCode: 200))
            } else if urlStr.contains("/pulls/191") {
                detailFetchCount += 1
                return (Data(), MockHTTPTransport.response(url: req.url!, statusCode: 200))
            }
            return (Data(), MockHTTPTransport.response(url: req.url!, statusCode: 404))
        }

        let connector = GitHubConnector(
            transport: transport,
            tokenProvider: MockTokenProvider(token: "gho_repo_only"),
            includeReviewRequestedSearch: true,
            includeMentionsSearchFallback: false,
            knownNotificationsScope: false,
            reconcileReviewRequestedNow: true,
            knownPRUpdatedAt: ["acme/web#191:reviewRequested": "2026-11-26T10:15:00Z"]
        )

        let batch = try await connector.poll(cursor: nil)
        #expect(detailFetchCount == 0)
        #expect(batch.suggestedPollIntervalSeconds == 180)
        #expect(batch.candidates.isEmpty)
    }

    @Test("Respects Retry-After and 429 rate-limit backoff")
    func handlesRateLimit429Backoff() async throws {
        let transport = MockHTTPTransport { req in
            (
                Data("{\"message\":\"secondary rate limit\"}".utf8),
                MockHTTPTransport.response(
                    url: req.url!,
                    statusCode: 429,
                    headers: ["Retry-After": "180"]
                )
            )
        }

        let connector = GitHubConnector(
            transport: transport,
            tokenProvider: MockTokenProvider(token: "gho_test")
        )

        await #expect(throws: GitHubConnectorError.rateLimited(retryAfterSeconds: 180)) {
            _ = try await connector.poll(cursor: nil)
        }
    }

    @Test("Re-request review notification uses head SHA instead of stale comment ID so fixes always trigger re-review [TASK-015][ITER-013]")
    func reRequestReviewNotificationUsesHeadSHA() async throws {
        let transport = MockHTTPTransport { req in
            let urlStr = req.url!.absoluteString
            if urlStr.contains("/notifications") {
                let json = """
                [{
                  "id": "notif-900",
                  "reason": "review_requested",
                  "updated_at": "2026-11-27T02:00:00Z",
                  "repository": { "full_name": "acme/backend" },
                  "subject": {
                    "title": "feat: auth",
                    "type": "PullRequest",
                    "url": "https://api.github.com/repos/acme/backend/pulls/482",
                    "latest_comment_url": "https://api.github.com/repos/acme/backend/issues/comments/77777"
                  }
                }]
                """
                return (Data(json.utf8), MockHTTPTransport.response(url: req.url!, statusCode: 200))
            } else if urlStr.contains("/pulls/482") {
                let json = """
                {
                  "number": 482,
                  "title": "feat: auth",
                  "html_url": "https://github.com/acme/backend/pull/482",
                  "draft": false,
                  "additions": 30,
                  "deletions": 5,
                  "changed_files": 2,
                  "updated_at": "2026-11-27T02:00:00Z",
                  "user": { "login": "alice" },
                  "base": { "ref": "main", "sha": "base01" },
                  "head": { "ref": "feat/auth", "sha": "newfixsha999999" }
                }
                """
                return (Data(json.utf8), MockHTTPTransport.response(url: req.url!, statusCode: 200))
            }
            return (Data(), MockHTTPTransport.response(url: req.url!, statusCode: 404))
        }

        let connector = GitHubConnector(
            transport: transport,
            tokenProvider: MockTokenProvider(token: "gho_test"),
            includeReviewRequestedSearch: false
        )

        let batch = try await connector.poll(cursor: nil)
        #expect(batch.candidates.count == 1)
        #expect(batch.candidates.first?.dedupeKey == "github:acme/backend#482:reviewRequested:newfixsha999999")
    }
}
