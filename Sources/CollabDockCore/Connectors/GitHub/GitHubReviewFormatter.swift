import Foundation

public struct GitHubReviewRequestPayload: Encodable, Equatable, Sendable {
    public struct DraftComment: Encodable, Equatable, Sendable {
        public let path: String
        public let line: Int
        public let side: String
        public let body: String

        public init(path: String, line: Int, side: String, body: String) {
            self.path = path
            self.line = line
            self.side = side
            self.body = body
        }
    }

    public let commitID: String
    public let body: String
    /// 省略（nil）时 GitHub API 创建仅本人可见的 Pending Review Draft！（关联 REQ-009, ADR-004）
    public let event: String?
    public let comments: [DraftComment]

    enum CodingKeys: String, CodingKey {
        case commitID = "commit_id"
        case body
        case event
        case comments
    }

    public init(commitID: String, body: String, event: String?, comments: [DraftComment]) {
        self.commitID = commitID
        self.body = body
        self.event = event
        self.comments = comments
    }
}

/// 构造 GitHub Pending Review 请求体与本地 Markdown 报告（含 Diff 行号越界自动降级，关联 REQ-009, TASK-013）
public enum GitHubReviewFormatter {
    public static func buildReviewPayload(
        review: CodeReviewResult,
        commitSHA: String,
        unifiedDiff: String?,
        mode: DeliveryMode
    ) -> GitHubReviewRequestPayload {
        let validator = DiffLineValidator()
        let partitioned: ValidatedReviewPayload
        if let unifiedDiff, !unifiedDiff.isEmpty {
            let validMap = validator.parseValidLines(from: unifiedDiff)
            partitioned = validator.partition(comments: review.comments, validLinesByFile: validMap)
        } else {
            // 若无 Diff 上下文，全部安全归入顶层 Summary 防止 GitHub API 422
            partitioned = ValidatedReviewPayload(
                validInlineComments: [],
                fallbackSummaryComments: review.comments
            )
        }

        let inlineDraftComments = partitioned.validInlineComments.map { comment in
            GitHubReviewRequestPayload.DraftComment(
                path: comment.path,
                line: comment.line,
                side: comment.side.rawValue,
                body: formatInlineCommentBody(comment)
            )
        }

        var bodySections: [String] = [review.summary]
        if !partitioned.fallbackSummaryComments.isEmpty {
            var lines: [String] = ["", "### 补充审查意见（变更行范围外）"]
            for c in partitioned.fallbackSummaryComments {
                lines.append("- **\(severityLabel(c.severity)) · `\(c.path):\(c.line)`** — **\(c.title)**：\(c.body)")
            }
            bodySections.append(lines.joined(separator: "\n"))
        }

        if mode == .directReply {
            bodySections.append("\n---\n*Assisted by CollabDock (local AI review)*")
        }

        let event: String? = (mode == .platformDraft) ? nil : "COMMENT"

        return GitHubReviewRequestPayload(
            commitID: commitSHA,
            body: bodySections.joined(separator: "\n"),
            event: event,
            comments: inlineDraftComments
        )
    }

    public static func formatInlineCommentBody(_ comment: CodeInlineComment) -> String {
        var text = "**[\(severityLabel(comment.severity))] \(comment.title)**\n\n\(comment.body)"
        if let suggestion = comment.suggestion?.trimmingCharacters(in: .whitespacesAndNewlines), !suggestion.isEmpty {
            text += "\n\n```suggestion\n\(suggestion)\n```"
        }
        return text
    }

    public static func renderLocalMarkdownReport(
        item: CollaborationItem,
        output: ExecutionOutput,
        plan: ExecutionPlan?
    ) -> String {
        var lines: [String] = [
            "# \(item.title)",
            "",
            "- **来源**：\(item.platform.displayName) · `\(item.displayContextTag)`",
            "- **链接**：\(item.url.absoluteString)",
            "- **触发者**：@\(item.triggeredBy)（\(item.triggerKind.badgeText)）"
        ]
        if let plan {
            lines.append("- **执行引擎**：\(plan.engine.displayName) · `\(plan.model)`（\(plan.effort.displayName)）")
        }
        lines.append("")

        switch output {
        case .codeReview(let review):
            lines.append("## 总体结论（建议：\(review.recommendedVerdict.rawValue)）")
            lines.append("")
            lines.append(review.summary)
            lines.append("")
            if !review.comments.isEmpty {
                lines.append("## 行级审查意见（共 \(review.comments.count) 条）")
                lines.append("")
                for c in review.comments {
                    lines.append("### [\(severityLabel(c.severity))] `\(c.path):\(c.line)` — \(c.title)")
                    lines.append("")
                    lines.append(c.body)
                    if let suggestion = c.suggestion, !suggestion.isEmpty {
                        lines.append("")
                        lines.append("```suggestion")
                        lines.append(suggestion)
                        lines.append("```")
                    }
                    lines.append("")
                }
            }

        case .structuredReply(let reply):
            lines.append("## 摘要")
            lines.append("")
            lines.append(reply.summary)
            lines.append("")
            lines.append("## 建议回复草稿")
            lines.append("")
            lines.append(reply.replyMarkdown)
            if !reply.keyPoints.isEmpty {
                lines.append("")
                lines.append("## 关键要点")
                for p in reply.keyPoints {
                    lines.append("- \(p)")
                }
            }
            if !reply.referencedFiles.isEmpty {
                lines.append("")
                lines.append("## 关联文件")
                for f in reply.referencedFiles {
                    lines.append("- `\(f)`")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    public static func saveLocalReport(
        markdown: String,
        itemID: String,
        reportsDirectory: URL? = nil
    ) throws -> URL {
        let dir: URL
        if let reportsDirectory {
            dir = reportsDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            dir = appSupport.appendingPathComponent("CollabDock/reports", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeName = itemID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: "") { $0.append($1) }
        let fileURL = dir.appendingPathComponent("\(safeName).md")
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private static func severityLabel(_ severity: FindingSeverity) -> String {
        switch severity {
        case .critical: return "🔴 严重"
        case .warning: return "🟡 建议"
        case .nit: return "⚪ 细节"
        }
    }
}
