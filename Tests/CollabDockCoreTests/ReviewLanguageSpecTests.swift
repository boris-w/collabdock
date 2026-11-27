import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：写回 GitHub 的文字（Pending Review 正文、行内评论、本地报告、多模型会诊合并说明）
/// 使用「审查语言」，而不是写死中文（issue #4）。
///
/// 断言刻意不约束具体措辞：AI 返回的内容是英文时，选英文审查语言后 CollabDock 自己加的标题 / 严重度 / 标签
/// 都不能再出现中文；选中文时保持现在的中文（以严重度标签「严重」为基线）。
@Suite("SPEC — review language controls the text CollabDock writes to GitHub (issue #4)")
struct ReviewLanguageSpecTests {
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) || (0x3000...0x303F).contains($0.value) }
    }

    private let inDiff = CodeInlineComment(
        path: "Sources/Cache.swift", line: 5, severity: .critical,
        title: "purge() does nothing", body: "Clear the storage here.",
        suggestion: "    mutating func purge() { storage.removeAll() }"
    )
    private let outOfDiff = CodeInlineComment(
        path: "Sources/Cache.swift", line: 250, severity: .nit,
        title: "Out-of-diff note", body: "Should be folded into the summary."
    )
    private let diff = """
    diff --git a/Sources/Cache.swift b/Sources/Cache.swift
    --- a/Sources/Cache.swift
    +++ b/Sources/Cache.swift
    @@ -3,3 +3,4 @@
     struct Cache {
         var storage: [String: Int] = [:]
    +    static let ttl = 60
     }
    """

    private var review: CodeReviewResult {
        CodeReviewResult(summary: "Adds a TTL constant.", recommendedVerdict: .requestChanges, comments: [inDiff, outOfDiff])
    }

    // MARK: pending review payload

    @Test("English review language: the pending review body and inline comments carry no Chinese")
    func englishPayload() {
        for mode in [DeliveryMode.platformDraft, .directReply] {
            let payload = GitHubReviewFormatter.buildReviewPayload(
                review: review, commitSHA: "abc123", unifiedDiff: diff, mode: mode, language: .en
            )
            #expect(!Self.containsCJK(payload.body), "body: \(payload.body)")
            #expect(payload.body.contains("Out-of-diff note"), "out-of-diff findings are still folded into the body")
            #expect(payload.comments.count == 1)
            for c in payload.comments {
                #expect(!Self.containsCJK(c.body), "comment: \(c.body)")
            }
        }
    }

    @Test("Chinese review language keeps today's Chinese labels")
    func chinesePayload() throws {
        let payload = GitHubReviewFormatter.buildReviewPayload(
            review: review, commitSHA: "abc123", unifiedDiff: diff, mode: .platformDraft, language: .zhHans
        )
        let inline = try #require(payload.comments.first)
        #expect(inline.body.contains("严重"))
        #expect(Self.containsCJK(payload.body), "the out-of-diff section heading is Chinese")
    }

    @Test("Inline comment body follows the review language")
    func inlineCommentBody() {
        #expect(!Self.containsCJK(GitHubReviewFormatter.formatInlineCommentBody(inDiff, language: .en)))
        #expect(GitHubReviewFormatter.formatInlineCommentBody(inDiff, language: .zhHans).contains("严重"))
        for severity in [FindingSeverity.critical, .warning, .nit] {
            let c = CodeInlineComment(path: "a.swift", line: 1, severity: severity, title: "t", body: "b")
            #expect(!Self.containsCJK(GitHubReviewFormatter.formatInlineCommentBody(c, language: .en)), "\(severity)")
        }
    }

    // MARK: local report

    @Test("English review language: the local Markdown report (code review and structured reply) carries no Chinese")
    func englishLocalReport() {
        let item = Fixtures.prItem()
        let plan = ExecutionPlan(engine: .claudeCode, model: "sonnet", effort: .high)
        let codeReport = GitHubReviewFormatter.renderLocalMarkdownReport(
            item: item, output: .codeReview(review), plan: plan, language: .en
        )
        #expect(!Self.containsCJK(codeReport), "\(codeReport)")
        #expect(codeReport.contains("purge() does nothing"))

        let reply = StructuredReplyResult(
            summary: "Root cause found.", replyMarkdown: "Restart the worker.",
            keyPoints: ["Timeout is 30s"], referencedFiles: ["Sources/Worker.swift"]
        )
        let replyReport = GitHubReviewFormatter.renderLocalMarkdownReport(
            item: item, output: .structuredReply(reply), plan: plan, language: .en
        )
        #expect(!Self.containsCJK(replyReport), "\(replyReport)")
        #expect(replyReport.contains("Restart the worker."))
    }

    @Test("Chinese review language keeps the Chinese local report")
    func chineseLocalReport() {
        let report = GitHubReviewFormatter.renderLocalMarkdownReport(
            item: Fixtures.prItem(), output: .codeReview(review), plan: nil, language: .zhHans
        )
        #expect(Self.containsCJK(report))
    }

    // MARK: council

    @Test("English review language: the multi-model consensus text carries no Chinese, and still names both models")
    func englishCouncil() throws {
        let a = CouncilContribution(label: "sonnet", output: .codeReview(CodeReviewResult(summary: "A says.", recommendedVerdict: .comment, comments: [inDiff])))
        let b = CouncilContribution(label: "gpt-5", output: .codeReview(CodeReviewResult(summary: "B says.", recommendedVerdict: .approve, comments: [inDiff])))
        let merged = CouncilSynthesizer.synthesize(primary: a, secondary: b, language: .en)
        guard case .codeReview(let r) = merged else { Issue.record("expected a code review"); return }
        #expect(!Self.containsCJK(r.summary), "\(r.summary)")
        let consensus = try #require(r.comments.first)
        #expect(!Self.containsCJK(consensus.title + consensus.body), "\(consensus.body)")
        #expect(consensus.body.contains("sonnet") && consensus.body.contains("gpt-5"))

        let replyA = CouncilContribution(label: "sonnet", output: .structuredReply(StructuredReplyResult(summary: "A.", replyMarkdown: "Reply A")))
        let replyB = CouncilContribution(label: "gpt-5", output: .structuredReply(StructuredReplyResult(summary: "B.", replyMarkdown: "Reply B")))
        guard case .structuredReply(let reply) = CouncilSynthesizer.synthesize(primary: replyA, secondary: replyB, language: .en) else {
            Issue.record("expected a structured reply"); return
        }
        #expect(!Self.containsCJK(reply.summary + reply.replyMarkdown + reply.keyPoints.joined()), "\(reply.replyMarkdown)")
    }

    // MARK: pipeline wiring

    @Test("The review language on the execution request reaches the delivery context")
    func serviceForwardsReviewLanguage() async throws {
        for language in [ResolvedLanguage.en, .zhHans] {
            let direct = FakeBackend(kind: .directCLI, engines: [.claudeCode, .codex, .antigravity], context: Fixtures.workspace(diff: "DIFF"))
            let lody = FakeBackend(kind: .lody, engines: [.lody], context: Fixtures.workspace(diff: "DIFF"))
            let sink = FakeSink()
            let service = ReviewExecutionService(directBackend: direct, lodyBackend: lody, sink: sink, store: InMemoryTaskStore())
            let item = Fixtures.prItem(status: .pendingConfirmation)
            direct.results[.claudeCode] = AgentRunResult(output: Fixtures.codeReview("ok"), sessionHandle: nil, rawOutputText: "")

            _ = try await service.execute(ReviewExecutionRequest(
                item: item,
                plan: ExecutionPlan(engine: .claudeCode, model: "sonnet", deliveryMode: .platformDraft),
                preset: TaskPreset.defaults[0],
                ticket: ExecutionRunTicket(itemID: item.id),
                searchRoots: [],
                preferredLocalPath: nil,
                reviewLanguage: language
            ))

            #expect(sink.deliveries.first?.context.language == language)
        }
    }

    @Test("Council runs merge in the review language")
    func councilUsesReviewLanguage() async throws {
        let direct = FakeBackend(kind: .directCLI, engines: [.claudeCode, .codex, .antigravity], context: Fixtures.workspace(diff: "DIFF"))
        let lody = FakeBackend(kind: .lody, engines: [.lody], context: Fixtures.workspace(diff: "DIFF"))
        let sink = FakeSink()
        let service = ReviewExecutionService(directBackend: direct, lodyBackend: lody, sink: sink, store: InMemoryTaskStore())
        let item = Fixtures.prItem(status: .pendingConfirmation)
        let comment = CodeInlineComment(path: "Sources/A.swift", line: 10, severity: .warning, title: "nil check", body: "guard it")
        direct.results[.claudeCode] = AgentRunResult(output: Fixtures.codeReview("A says", comments: [comment]), sessionHandle: nil, rawOutputText: "")
        direct.results[.codex] = AgentRunResult(output: Fixtures.codeReview("B says", comments: [comment]), sessionHandle: nil, rawOutputText: "")

        _ = try await service.execute(ReviewExecutionRequest(
            item: item,
            plan: ExecutionPlan(engine: .claudeCode, model: "sonnet", councilPartner: CouncilPartner(engine: .codex, model: "gpt-5", effort: .high)),
            preset: TaskPreset.defaults[0],
            ticket: ExecutionRunTicket(itemID: item.id),
            searchRoots: [],
            preferredLocalPath: nil,
            reviewLanguage: .en
        ))

        guard case .codeReview(let merged)? = sink.deliveries.first?.output else { Issue.record("expected a merged review"); return }
        #expect(!Self.containsCJK(merged.summary + merged.comments.map { $0.title + $0.body }.joined()), "\(merged.summary)")
    }

    @Test("Without an explicit review language, delivery keeps the current Chinese output (backwards compatible default)")
    func defaultIsChinese() {
        #expect(DeliveryContext().language == .zhHans)
    }
}
