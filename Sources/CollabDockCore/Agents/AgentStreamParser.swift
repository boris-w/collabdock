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

/// Lody CLI `--json` 输出解析器（提取 Lody 会话 ID、纯文本进度行与流式用量指标）
public enum AgentStreamParser {
    public static func parseLine(_ rawLine: String) -> ParsedStreamLine {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParsedStreamLine() }

        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ParsedStreamLine(progressHint: String(trimmed.prefix(120)))
        }

        let resultObj = obj["result"] as? [String: Any]
        let sessionID = firstString(in: obj, keys: ["sessionId", "session_id"])
            ?? (obj["session"] as? [String: Any]).flatMap { firstString(in: $0, keys: ["id", "sessionId"]) }

        let type = ((obj["type"] as? String) ?? (obj["event"] as? String))?.lowercased() ?? ""
        let (usageMetrics, isFinalUsage) = extractUsage(from: obj, resultObj: resultObj, type: type)

        return ParsedStreamLine(
            sessionID: sessionID,
            progressHint: nil,
            finalText: nil,
            usage: usageMetrics,
            isFinalUsage: isFinalUsage
        )
    }

    private static func extractUsage(
        from obj: [String: Any],
        resultObj: [String: Any]?,
        type: String
    ) -> (AgentUsageMetrics?, Bool) {
        let isFinal = (type == "result" || type == "turn.completed")

        let usageDict: [String: Any]?
        if let u = resultObj?["usage"] as? [String: Any] {
            usageDict = u
        } else if let u = obj["usage"] as? [String: Any] {
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

    private static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let val = dict[key] as? String, !val.isEmpty {
                return val
            }
        }
        return nil
    }
}
