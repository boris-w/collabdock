import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：选英文审查语言时，真正 POST 到 GitHub 的 Pending Review 与落盘的本地报告里
/// 没有 CollabDock 自己加的中文（AI 返回的审查内容本身是英文）。issue #4。
@Suite("E2E SPEC — review language reaches the real GitHub payload and local report", .serialized, .enabled(if: GitSandbox.isGitAvailable))
struct ReviewLanguageE2ETests {
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) || (0x3000...0x303F).contains($0.value) }
    }

    @Test("English review language: pending review body, inline comments and local report are free of Chinese")
    func englishDelivery() async throws {
        let scenario = try await PRScenario.make()
        defer { scenario.sandbox.cleanup() }
        let item = try #require(try await scenario.connector.poll(cursor: nil).candidates.first?.item)
        let context = try await scenario.prepare(item)
        let output = try #require(AgentStreamParser.decodeExecutionOutput(from: SampleReview.json, for: item))
        let reports = scenario.sandbox.root.appendingPathComponent("reports", isDirectory: true)

        let receipt = try await scenario.connector.deliver(
            output: output,
            for: item,
            mode: .platformDraft,
            context: DeliveryContext(
                plan: ExecutionPlan(engine: .claudeCode, model: "sonnet", effort: .medium),
                unifiedDiff: context.unifiedDiff,
                reportsDirectory: reports,
                language: .en
            )
        )

        let post = try #require(scenario.github.requests("POST", "/repos/\(PRScenario.repository)/pulls/\(PRScenario.number)/reviews").first)
        let body = try #require(post.jsonBody)
        let reviewBody = try #require(body["body"] as? String)
        #expect(!Self.containsCJK(reviewBody), "review body: \(reviewBody)")
        #expect(reviewBody.contains("Out-of-diff note"))
        let comments = try #require(body["comments"] as? [[String: Any]])
        #expect(comments.count == 1)
        for c in comments {
            let text = try #require(c["body"] as? String)
            #expect(!Self.containsCJK(text), "inline comment: \(text)")
        }

        let reportPath = try #require(receipt.localReportPath)
        let report = try String(contentsOf: reportPath, encoding: .utf8)
        #expect(!Self.containsCJK(report), "local report: \(report)")
        #expect(report.contains("purge() does nothing"))
    }
}
