import Foundation

public struct CouncilContribution: Sendable {
    public let label: String
    public let output: ExecutionOutput

    public init(label: String, output: ExecutionOutput) {
        self.label = label
        self.output = output
    }
}

/// 多模型会诊汇总器：交叉比对同一文件 ±3 行内的重叠发现并提权标注为「多模型共识」（关联 REQ-010, TASK-017）
public enum CouncilSynthesizer {
    public static func synthesize(
        primary: CouncilContribution,
        secondary: CouncilContribution,
        lineProximityThreshold: Int = 3,
        language: ResolvedLanguage = .zhHans
    ) -> ExecutionOutput {
        switch (primary.output, secondary.output) {
        case (.codeReview(let r1), .codeReview(let r2)):
            return .codeReview(
                mergeCodeReviews(
                    label1: primary.label,
                    review1: r1,
                    label2: secondary.label,
                    review2: r2,
                    proximity: lineProximityThreshold,
                    language: language
                )
            )
        default:
            return .structuredReply(
                mergeStructuredReplies(primary: primary, secondary: secondary, language: language)
            )
        }
    }

    private static func mergeCodeReviews(
        label1: String,
        review1: CodeReviewResult,
        label2: String,
        review2: CodeReviewResult,
        proximity: Int,
        language: ResolvedLanguage
    ) -> CodeReviewResult {
        var matchedSecondIndices: Set<Int> = []
        var mergedComments: [CodeInlineComment] = []
        var consensusCount = 0

        for c1 in review1.comments {
            if let matchIdx = review2.comments.enumerated().first(where: { idx, c2 in
                !matchedSecondIndices.contains(idx)
                    && c1.path == c2.path
                    && c1.side == c2.side
                    && abs(c1.line - c2.line) <= proximity
            })?.offset {
                matchedSecondIndices.insert(matchIdx)
                consensusCount += 1
                let c2 = review2.comments[matchIdx]
                let mergedSeverity = higherSeverity(c1.severity, c2.severity)
                let combinedBody = CoreL10n.format(
                    "**%@**: %@\n\n**%@**: %@",
                    language: language,
                    label1,
                    c1.body,
                    label2,
                    c2.body
                )
                mergedComments.append(
                    CodeInlineComment(
                        path: c1.path,
                        line: c1.line,
                        side: c1.side,
                        severity: mergedSeverity,
                        title: CoreL10n.format("🤝 Consensus · %@", language: language, c1.title),
                        body: combinedBody,
                        suggestion: c1.suggestion ?? c2.suggestion
                    )
                )
            } else {
                mergedComments.append(
                    CodeInlineComment(
                        path: c1.path,
                        line: c1.line,
                        side: c1.side,
                        severity: c1.severity,
                        title: "[\(label1)] \(c1.title)",
                        body: c1.body,
                        suggestion: c1.suggestion
                    )
                )
            }
        }

        for (idx, c2) in review2.comments.enumerated() where !matchedSecondIndices.contains(idx) {
            mergedComments.append(
                CodeInlineComment(
                    path: c2.path,
                    line: c2.line,
                    side: c2.side,
                    severity: c2.severity,
                    title: "[\(label2)] \(c2.title)",
                    body: c2.body,
                    suggestion: c2.suggestion
                )
            )
        }

        // 排序：严重程度高优先，共识优先
        mergedComments.sort { lhs, rhs in
            let lRank = severityRank(lhs.severity)
            let rRank = severityRank(rhs.severity)
            if lRank != rRank { return lRank > rRank }
            let lConsensus = lhs.title.hasPrefix("🤝")
            let rConsensus = rhs.title.hasPrefix("🤝")
            if lConsensus != rConsensus { return lConsensus }
            return lhs.path < rhs.path
        }

        let summary = CoreL10n.format(
            "**Multi-model council complete (%@ × %@)**: %lld findings in total, including **%lld consensus findings**.\n\n- **%@**: %@\n- **%@**: %@",
            language: language,
            label1,
            label2,
            mergedComments.count,
            consensusCount,
            label1,
            review1.summary,
            label2,
            review2.summary
        )

        let verdict: ReviewVerdict
        if review1.recommendedVerdict == .requestChanges || review2.recommendedVerdict == .requestChanges {
            verdict = .requestChanges
        } else if review1.recommendedVerdict == .approve && review2.recommendedVerdict == .approve {
            verdict = .approve
        } else {
            verdict = .comment
        }

        return CodeReviewResult(
            summary: summary,
            recommendedVerdict: verdict,
            comments: mergedComments
        )
    }

    private static func mergeStructuredReplies(
        primary: CouncilContribution,
        secondary: CouncilContribution,
        language: ResolvedLanguage
    ) -> StructuredReplyResult {
        let s1 = primary.output.summaryText
        let s2 = secondary.output.summaryText

        let md1: String
        let pts1: [String]
        let files1: [String]
        if case .structuredReply(let r1) = primary.output {
            md1 = r1.replyMarkdown
            pts1 = r1.keyPoints
            files1 = r1.referencedFiles
        } else {
            md1 = s1
            pts1 = []
            files1 = []
        }

        let md2: String
        let pts2: [String]
        let files2: [String]
        if case .structuredReply(let r2) = secondary.output {
            md2 = r2.replyMarkdown
            pts2 = r2.keyPoints
            files2 = r2.referencedFiles
        } else {
            md2 = s2
            pts2 = []
            files2 = []
        }

        let combinedSummary = CoreL10n.format(
            "Two-model council (%@ × %@): %@ / %@",
            language: language,
            primary.label,
            secondary.label,
            s1,
            s2
        )
        let combinedMarkdown = CoreL10n.format(
            "### %@ Perspective\n%@\n\n### %@ Perspective\n%@",
            language: language,
            primary.label,
            md1,
            secondary.label,
            md2
        )
        let uniqueFiles = Array(NSOrderedSet(array: files1 + files2).compactMap { $0 as? String })

        return StructuredReplyResult(
            summary: combinedSummary,
            replyMarkdown: combinedMarkdown,
            keyPoints: pts1 + pts2,
            referencedFiles: uniqueFiles
        )
    }

    private static func higherSeverity(_ a: FindingSeverity, _ b: FindingSeverity) -> FindingSeverity {
        severityRank(a) >= severityRank(b) ? a : b
    }

    private static func severityRank(_ s: FindingSeverity) -> Int {
        switch s {
        case .critical: return 3
        case .warning: return 2
        case .nit: return 1
        }
    }
}
