import Testing
@testable import CollabDockCore

@Suite("CouncilSynthesizer Multi-Model Tests [REQ-010][TASK-017]")
struct CouncilSynthesizerTests {
    @Test("Merges overlapping findings within +-3 lines into consensus findings with elevated severity")
    func mergesConsensusAndDistinctFindings() {
        let claudeReview = CodeReviewResult(
            summary: "发现 1 处鉴权风险",
            recommendedVerdict: .requestChanges,
            comments: [
                CodeInlineComment(
                    path: "Sources/Auth.swift",
                    line: 42,
                    side: .right,
                    severity: .warning,
                    title: "JWT 过期未校验",
                    body: "exp 字段缺少校验",
                    suggestion: "guard claims.exp > Date() else { throw AuthError.expired }"
                ),
                CodeInlineComment(
                    path: "Sources/Cache.swift",
                    line: 10,
                    side: .right,
                    severity: .nit,
                    title: "变量命名可更清晰",
                    body: "建议重命名为 jwksCache"
                )
            ]
        )

        let codexReview = CodeReviewResult(
            summary: "高危鉴权绕过风险",
            recommendedVerdict: .comment,
            comments: [
                CodeInlineComment(
                    path: "Sources/Auth.swift",
                    line: 44,
                    side: .right,
                    severity: .critical,
                    title: "Token 有效期绕过",
                    body: "过期 Token 会继续通过校验"
                ),
                CodeInlineComment(
                    path: "Sources/Metrics.swift",
                    line: 88,
                    side: .right,
                    severity: .warning,
                    title: "指标标签高基数风险",
                    body: "不要把 userID 作为 label"
                )
            ]
        )

        let merged = CouncilSynthesizer.synthesize(
            primary: CouncilContribution(label: "Claude/opus", output: .codeReview(claudeReview)),
            secondary: CouncilContribution(label: "Codex/gpt-5.3", output: .codeReview(codexReview))
        )

        guard case .codeReview(let result) = merged else {
            Issue.record("Expected .codeReview")
            return
        }

        #expect(result.recommendedVerdict == .requestChanges)
        #expect(result.summary.contains("1 条为双方共识问题"))
        #expect(result.comments.count == 3)

        // 第一条应是提权为 critical 的共识问题
        let first = result.comments[0]
        #expect(first.severity == .critical)
        #expect(first.title.hasPrefix("🤝 共识"))
        #expect(first.body.contains("Claude/opus"))
        #expect(first.body.contains("Codex/gpt-5.3"))
        #expect(first.suggestion?.contains("claims.exp") == true)
    }

    @Test("Merges structured replies for conversation/issue troubleshooting")
    func mergesStructuredReplies() {
        let outA = ExecutionOutput.structuredReply(
            StructuredReplyResult(
                summary: "连接池等待超时",
                replyMarkdown: "建议增大 maxPoolSize",
                keyPoints: ["连接池耗尽"],
                referencedFiles: ["Sources/DB.swift"]
            )
        )
        let outB = ExecutionOutput.structuredReply(
            StructuredReplyResult(
                summary: "重试缺少退避",
                replyMarkdown: "建议增加指数退避",
                keyPoints: ["无退避重试风暴"],
                referencedFiles: ["Sources/DB.swift", "Sources/Retry.swift"]
            )
        )

        let merged = CouncilSynthesizer.synthesize(
            primary: CouncilContribution(label: "Claude", output: outA),
            secondary: CouncilContribution(label: "Antigravity", output: outB)
        )

        guard case .structuredReply(let reply) = merged else {
            Issue.record("Expected .structuredReply")
            return
        }
        #expect(reply.replyMarkdown.contains("Claude 观点"))
        #expect(reply.replyMarkdown.contains("Antigravity 观点"))
        #expect(reply.referencedFiles == ["Sources/DB.swift", "Sources/Retry.swift"])
    }
}
