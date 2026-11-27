import Foundation

public struct ValidatedReviewPayload: Equatable, Sendable {
    public let validInlineComments: [CodeInlineComment]
    public let fallbackSummaryComments: [CodeInlineComment]

    public init(
        validInlineComments: [CodeInlineComment],
        fallbackSummaryComments: [CodeInlineComment]
    ) {
        self.validInlineComments = validInlineComments
        self.fallbackSummaryComments = fallbackSummaryComments
    }
}

/// 代码托管平台共享 Unified Diff Hunk 行号校验器（GitHub PR / GitLab MR 共用，关联 REQ-009, ADR-004, ADR-005）
public struct DiffLineValidator: Sendable {
    public struct FileValidLines: Equatable, Sendable {
        public var leftLines: Set<Int>
        public var rightLines: Set<Int>

        public init(leftLines: Set<Int> = [], rightLines: Set<Int> = []) {
            self.leftLines = leftLines
            self.rightLines = rightLines
        }
    }

    public init() {}

    public func parseValidLines(from unifiedDiff: String) -> [String: FileValidLines] {
        var result: [String: FileValidLines] = [:]
        var currentPath: String?
        var oldLine = 0
        var newLine = 0
        var inHunk = false

        let lines = unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in lines {
            let line = String(rawLine)

            if line.hasPrefix("diff --git ") {
                currentPath = nil
                inHunk = false
                continue
            }

            if line.hasPrefix("+++ b/") {
                currentPath = String(line.dropFirst(6))
                if let path = currentPath, result[path] == nil {
                    result[path] = FileValidLines()
                }
                continue
            }

            if line.hasPrefix("+++ /dev/null") {
                continue
            }

            if line.hasPrefix("--- a/") && currentPath == nil {
                currentPath = String(line.dropFirst(6))
                if let path = currentPath, result[path] == nil {
                    result[path] = FileValidLines()
                }
                continue
            }

            if line.hasPrefix("@@ ") {
                if let (parsedOld, parsedNew) = parseHunkHeader(line) {
                    oldLine = parsedOld
                    newLine = parsedNew
                    inHunk = true
                }
                continue
            }

            guard inHunk, let path = currentPath else { continue }

            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                result[path, default: FileValidLines()].rightLines.insert(newLine)
                newLine += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                result[path, default: FileValidLines()].leftLines.insert(oldLine)
                oldLine += 1
            } else if line.hasPrefix(" ") {
                result[path, default: FileValidLines()].leftLines.insert(oldLine)
                result[path, default: FileValidLines()].rightLines.insert(newLine)
                oldLine += 1
                newLine += 1
            }
        }

        return result
    }

    public func partition(
        comments: [CodeInlineComment],
        validLinesByFile: [String: FileValidLines]
    ) -> ValidatedReviewPayload {
        var valid: [CodeInlineComment] = []
        var fallback: [CodeInlineComment] = []

        for comment in comments {
            guard let fileLines = validLinesByFile[comment.path] else {
                fallback.append(comment)
                continue
            }
            let isValid = (comment.side == .left)
                ? fileLines.leftLines.contains(comment.line)
                : fileLines.rightLines.contains(comment.line)
            if isValid {
                valid.append(comment)
            } else {
                fallback.append(comment)
            }
        }

        return ValidatedReviewPayload(
            validInlineComments: valid,
            fallbackSummaryComments: fallback
        )
    }

    private func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        let pattern = #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 3,
              let oldRange = Range(match.range(at: 1), in: line),
              let newRange = Range(match.range(at: 2), in: line),
              let oldStart = Int(line[oldRange]),
              let newStart = Int(line[newRange]) else {
            return nil
        }
        return (oldStart, newStart)
    }
}
