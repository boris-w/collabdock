import Foundation
import Testing
@testable import CollabDockCore

private struct DeliveryMockTokenProvider: GitHubTokenProvider {
    let token: String?
    func fetchToken() async -> String? { token }
}

private final class DeliveryMockHTTP: HTTPTransport, @unchecked Sendable {
    var capturedRequests: [URLRequest] = []
    var responder: (URLRequest) -> (Data, HTTPURLResponse)

    init(responder: @escaping (URLRequest) -> (Data, HTTPURLResponse)) {
        self.responder = responder
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequests.append(request)
        return responder(request)
    }
}

@Suite("GitHub Pending Review Delivery Tests [REQ-009][ADR-004][TASK-013]")
struct GitHubDeliveryTests {
    let sampleDiff = """
    diff --git a/Sources/Auth.swift b/Sources/Auth.swift
    --- a/Sources/Auth.swift
    +++ b/Sources/Auth.swift
    @@ -10,3 +10,4 @@ func verify() {
         let h = req.header
    +    let t = parse(h)
         return t
     }
    """

    let sampleReview = CodeReviewResult(
        summary: "整体清晰，但有 1 处安全建议。",
        recommendedVerdict: .comment,
        comments: [
            CodeInlineComment(
                path: "Sources/Auth.swift",
                line: 11,
                side: .right,
                severity: .warning,
                title: "需校验空 Header",
                body: "建议先做 guard",
                suggestion: "guard !h.isEmpty else { return nil }"
            ),
            CodeInlineComment(
                path: "Sources/Auth.swift",
                line: 250,
                side: .right,
                severity: .nit,
                title: "越界行测试",
                body: "应降级到顶层摘要"
            )
        ]
    )

    @Test("Builds Pending Review payload without 'event' key and moves out-of-hunk comments to body")
    func pendingDraftPayloadOmitsEvent() throws {
        let payload = GitHubReviewFormatter.buildReviewPayload(
            review: sampleReview,
            commitSHA: "headsha123",
            unifiedDiff: sampleDiff,
            mode: .platformDraft
        )

        #expect(payload.event == nil)
        #expect(payload.comments.count == 1)
        #expect(payload.comments[0].line == 11)
        #expect(payload.comments[0].body.contains("```suggestion"))
        #expect(payload.body.contains("Sources/Auth.swift:250"))

        // 确认序列化后的 JSON 中不含 "event" 键（GitHub 据此创建 Pending Draft）
        let jsonData = try JSONEncoder().encode(payload)
        let jsonObj = try #require(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        #expect(jsonObj["event"] == nil)
        #expect(jsonObj["commit_id"] as? String == "headsha123")
    }

    @Test("Delivers Pending Review Draft via POST /pulls/:number/reviews and writes local Markdown report")
    func deliverPendingReviewAndSaveReport() async throws {
        let reportsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-reports-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: reportsDir) }

        let mockHTTP = DeliveryMockHTTP { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data("{\"id\":9001,\"state\":\"PENDING\"}".utf8), resp)
        }

        let connector = GitHubConnector(
            transport: mockHTTP,
            tokenProvider: DeliveryMockTokenProvider(token: "gho_test")
        )

        let item = CollaborationItem(
            id: "gh:acme/backend#482",
            platform: .github,
            itemKind: .pullRequest,
            scope: "acme/backend",
            externalRef: "#482",
            title: "feat: jwks",
            url: URL(string: "https://github.com/acme/backend/pull/482")!,
            author: "alice",
            triggeredBy: "alice",
            triggerKind: .mention,
            payload: .codeChange(
                CodeChangePayload(
                    repository: "acme/backend",
                    number: 482,
                    baseRef: "main",
                    headRef: "feat/jwks",
                    headSHA: "abc1234",
                    additions: 10,
                    deletions: 2,
                    changedFiles: 1
                )
            )
        )

        let receipt = try await connector.deliver(
            output: .codeReview(sampleReview),
            for: item,
            mode: .platformDraft,
            plan: ExecutionPlan(engine: .claudeCode, model: "opus"),
            unifiedDiff: sampleDiff,
            reportsDirectory: reportsDir
        )

        #expect(receipt.deliveredMode == .platformDraft)
        #expect(receipt.destinationURL?.absoluteString == "https://github.com/acme/backend/pull/482/files")
        let reportPath = try #require(receipt.localReportPath)
        #expect(FileManager.default.fileExists(atPath: reportPath.path))

        let postReq = try #require(mockHTTP.capturedRequests.first)
        #expect(postReq.httpMethod == "POST")
        #expect(postReq.url?.absoluteString.hasSuffix("/repos/acme/backend/pulls/482/reviews") == true)
    }

    @Test("Maps GitHub 422 existing pending review to actionable domain error")
    func handlesExistingPendingReview422() async throws {
        let reportsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-reports-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: reportsDir) }

        let mockHTTP = DeliveryMockHTTP { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data("{\"message\":\"User can only have one pending review per pull request\"}".utf8), resp)
        }

        let connector = GitHubConnector(
            transport: mockHTTP,
            tokenProvider: DeliveryMockTokenProvider(token: "gho_test")
        )

        let item = CollaborationItem(
            id: "gh:acme/backend#482",
            platform: .github,
            itemKind: .pullRequest,
            scope: "acme/backend",
            externalRef: "#482",
            title: "feat: jwks",
            url: URL(string: "https://github.com/acme/backend/pull/482")!,
            author: "alice",
            triggeredBy: "alice",
            triggerKind: .mention,
            payload: .codeChange(
                CodeChangePayload(repository: "acme/backend", number: 482, baseRef: "main", headRef: "feat/jwks", headSHA: "abc", additions: 1, deletions: 0, changedFiles: 1)
            )
        )

        await #expect(throws: GitHubConnectorError.pendingReviewAlreadyExists) {
            _ = try await connector.deliver(
                output: .codeReview(sampleReview),
                for: item,
                mode: .platformDraft,
                plan: nil,
                unifiedDiff: sampleDiff,
                reportsDirectory: reportsDir
            )
        }
    }
}
