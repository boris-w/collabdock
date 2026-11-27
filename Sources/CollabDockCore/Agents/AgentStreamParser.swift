import Foundation

public struct ParsedStreamLine: Equatable, Sendable {
    public let sessionID: String?
    public let progressHint: String?
    public let finalText: String?
    public let usage: AgentUsageMetrics?
    /// 标识该条 usage 是来自最终汇总事件（result / turn.completed），优先覆盖中间步骤计数
    public let isFinalUsage: Bool

    public init(
        sessionID: String? = nil,
        progressHint: String? = nil,
        finalText: String? = nil,
        usage: AgentUsageMetrics? = nil,
        isFinalUsage: Bool = false
    ) {
        self.sessionID = sessionID
        self.progressHint = progressHint
        self.finalText = finalText
        self.usage = usage
        self.isFinalUsage = isFinalUsage
    }
}

/// 跨引擎流式 JSON 与结构化结果解析器（兼容 Claude / Codex / Antigravity / Lody，关联 REQ-007, TASK-012）
public enum AgentStreamParser {
    public static func parseLine(_ rawLine: String) -> ParsedStreamLine {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParsedStreamLine() }

        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // 非 JSON 行：可能是 `claude --bg` 打印的纯文本 session id 或进度
            if let bgID = extractSessionIDFromPlainText(trimmed) {
                return ParsedStreamLine(
                    sessionID: bgID,
                    progressHint: CoreL10n.format("Background session created: %@", bgID)
                )
            }
            return ParsedStreamLine(progressHint: String(trimmed.prefix(120)))
        }

        let resultObj = obj["result"] as? [String: Any]
        let stepUpdateObj = obj["step_update"] as? [String: Any]

        let sessionID = firstString(in: obj, keys: ["session_id", "sessionId", "conversation_id", "conversationId", "thread_id", "threadId"])
            ?? (obj["session"] as? [String: Any]).flatMap { firstString(in: $0, keys: ["id", "sessionId"]) }
            ?? resultObj.flatMap { firstString(in: $0, keys: ["conversation_id", "conversationId", "session_id", "sessionId"]) }
            ?? stepUpdateObj.flatMap { firstString(in: $0, keys: ["conversation_id", "conversationId"]) }

        var progress: String?
        var finalText: String?

        let type = ((obj["type"] as? String) ?? (obj["event"] as? String))?.lowercased() ?? ""

        // 1. 提取最终结构化文本/对象（兼容 Claude 顶层与 Antigravity 嵌套 `result: { response / structured_output }`）
        if let structured = obj["structured_output"] ?? resultObj?["structured_output"],
           let jsonData = try? JSONSerialization.data(withJSONObject: structured),
           let str = String(data: jsonData, encoding: .utf8) {
            finalText = str
        } else if let resultStr = obj["result"] as? String, !resultStr.isEmpty {
            finalText = resultStr
        } else if let nestedResponse = resultObj?["response"] as? String, !nestedResponse.isEmpty {
            finalText = nestedResponse
        } else if let nestedResult = resultObj?["result"] as? String, !nestedResult.isEmpty {
            finalText = nestedResult
        } else if let responseStr = obj["response"] as? String, !responseStr.isEmpty {
            finalText = responseStr
        } else if let item = obj["item"] as? [String: Any],
                  let text = firstString(in: item, keys: ["text", "content"]) {
            if type.contains("completed") {
                finalText = text
            } else {
                progress = String(text.prefix(100))
            }
        }

        // 2. 提取可读进度提示（正在调什么工具 / 读什么文件）
        if let stepTool = stepUpdateObj?["tool_name"] as? String, !stepTool.isEmpty {
            if let toolInfo = stepUpdateObj?["tool_info"] as? [String: Any],
               let params = toolInfo["parameters"] as? [String: Any],
               let target = firstString(in: params, keys: ["Path", "AbsolutePath", "file_path", "path", "Query", "CommandLine"]) {
                let shortTarget = (target as NSString).lastPathComponent
                progress = CoreL10n.format("Running %@: %@", stepTool, shortTarget)
            } else {
                progress = CoreL10n.format("Calling tool: %@", stepTool)
            }
        } else if let toolName = firstString(in: obj, keys: ["tool_name", "toolName", "name"]) {
            progress = CoreL10n.format("Calling tool: %@", toolName)
        } else if let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] {
            for block in content {
                let blockType = (block["type"] as? String)?.lowercased() ?? ""
                if blockType == "tool_use", let name = block["name"] as? String {
                    if let input = block["input"] as? [String: Any],
                       let filePath = firstString(in: input, keys: ["file_path", "path", "pattern", "command"]) {
                        let shortTarget = (filePath as NSString).lastPathComponent
                        progress = CoreL10n.format("Running %@: %@", name, shortTarget)
                    } else {
                        progress = CoreL10n.format("Running %@...", name)
                    }
                    break
                } else if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                    finalText = text
                    progress = CoreL10n.string("Summarizing review findings...")
                }
            }
        } else if type == "system" || type == "init" {
            progress = CoreL10n.string("Session initialized, starting code analysis...")
        } else if type == "step_update", (stepUpdateObj?["step_type"] as? String) == "agent_response" {
            progress = CoreL10n.string("Generating review findings...")
        }

        let (usageMetrics, isFinalUsage) = extractUsage(from: obj, resultObj: resultObj, stepUpdateObj: stepUpdateObj, type: type)

        return ParsedStreamLine(
            sessionID: sessionID,
            progressHint: progress,
            finalText: finalText,
            usage: usageMetrics,
            isFinalUsage: isFinalUsage
        )
    }

    private static func extractUsage(
        from obj: [String: Any],
        resultObj: [String: Any]?,
        stepUpdateObj: [String: Any]?,
        type: String
    ) -> (AgentUsageMetrics?, Bool) {
        let isFinal = (type == "result" || type == "turn.completed")

        let usageDict: [String: Any]?
        if let u = resultObj?["usage"] as? [String: Any] {
            usageDict = u
        } else if let u = obj["usage"] as? [String: Any] {
            usageDict = u
        } else if let u = stepUpdateObj?["usage"] as? [String: Any] {
            usageDict = u
        } else {
            usageDict = nil
        }

        guard let u = usageDict else { return (nil, false) }

        let input = intValue(u, keys: ["input_tokens", "inputTokens", "prompt_tokens"])
        let output = intValue(u, keys: ["output_tokens", "outputTokens", "completion_tokens"])
        let cacheRead = intValue(u, keys: ["cache_read_input_tokens", "cache_read_tokens", "cached_input_tokens", "cacheReadTokens"])
        let cacheCreate = intValue(u, keys: ["cache_creation_input_tokens", "cache_creation_tokens", "cacheCreationTokens"])
        let thinking = intValue(u, keys: ["thinking_tokens", "reasoning_tokens", "thinkingTokens"])
        let total = intValue(u, keys: ["total_tokens", "totalTokens"])

        guard input > 0 || output > 0 || cacheRead > 0 || thinking > 0 || total > 0 else {
            return (nil, false)
        }

        let costUSD = doubleValue(resultObj ?? obj, keys: ["total_cost_usd", "cost_usd"])
            ?? doubleValue(obj, keys: ["total_cost_usd", "cost_usd"])

        let durationSec: Double? = {
            if let sec = doubleValue(resultObj ?? obj, keys: ["duration_seconds"]) {
                return sec
            }
            if let ms = doubleValue(resultObj ?? obj, keys: ["duration_ms"]) {
                return ms / 1000.0
            }
            return nil
        }()

        let metrics = AgentUsageMetrics(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreate,
            thinkingTokens: thinking,
            totalTokens: total > 0 ? total : nil,
            reportedCostUSD: costUSD,
            durationSeconds: durationSec,
            metricKind: .exact
        )
        return (metrics, isFinal)
    }

    private static func intValue(_ dict: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let n = dict[key] as? Int { return n }
            if let n = dict[key] as? NSNumber { return n.intValue }
        }
        return 0
    }

    private static func doubleValue(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let d = dict[key] as? Double { return d }
            if let n = dict[key] as? NSNumber { return n.doubleValue }
        }
        return nil
    }

    public static func decodeExecutionOutput(
        from rawText: String,
        for item: CollaborationItem
    ) -> ExecutionOutput? {
        let candidateJSON = extractJSONObjectString(from: rawText) ?? rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = candidateJSON.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        switch item.payload {
        case .codeChange:
            if let review = try? decoder.decode(CodeReviewResult.self, from: data) {
                return .codeReview(review)
            }
            if let reply = try? decoder.decode(StructuredReplyResult.self, from: data) {
                return .structuredReply(reply)
            }
        case .issueTicket, .conversation:
            if let reply = try? decoder.decode(StructuredReplyResult.self, from: data) {
                return .structuredReply(reply)
            }
            if let review = try? decoder.decode(CodeReviewResult.self, from: data) {
                return .codeReview(review)
            }
        }
        return nil
    }

    /// 容错提取被 Markdown 代码块或前后缀包裹的最外层 JSON 对象
    public static func extractJSONObjectString(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            return trimmed
        }
        // 优先匹配 ```json ... ```
        if let regex = try? NSRegularExpression(pattern: #"```(?:json)?\s*(\{[\s\S]*?\})\s*```"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range),
               match.numberOfRanges > 1,
               let capture = Range(match.range(at: 1), in: text) {
                return String(text[capture])
            }
        }
        // 兜底：截取首个 `{` 到最后一个 `}`
        guard let firstBrace = text.firstIndex(of: "{"),
              let lastBrace = text.lastIndex(of: "}"),
              firstBrace < lastBrace else {
            return nil
        }
        return String(text[firstBrace...lastBrace])
    }

    private static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let val = dict[key] as? String, !val.isEmpty {
                return val
            }
        }
        return nil
    }

    private static func extractSessionIDFromPlainText(_ line: String) -> String? {
        let pattern = #"(?:session[_\-\s]?id[:=\s]+|id[:=\s]+)([A-Za-z0-9_\-]{6,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[capture])
    }
}
