import Foundation

// MARK: - 用量与参考成本模型（借鉴 Magpie × CodexBar，关联 ITER-014）

public enum UsageCurrency: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case usd
    case cny

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .usd: return "$"
        case .cny: return "¥"
        }
    }

    public var displayName: String {
        switch self {
        case .usd: return "USD ($)"
        case .cny: return "CNY (¥)"
        }
    }

    /// 参考汇率（仅用于订阅/API 等价成本展示）
    public static let usdToCnyRate: Double = 7.25

    public func convert(usd: Double) -> Double {
        switch self {
        case .usd: return usd
        case .cny: return usd * Self.usdToCnyRate
        }
    }

    public func format(usd: Double) -> String {
        let val = convert(usd: usd)
        if val <= 0 {
            return "\(symbol)0.00"
        }
        if val < 0.01 {
            return "<\(symbol)0.01"
        }
        if val >= 100 {
            return String(format: "%@%.1f", symbol, val)
        }
        return String(format: "%@%.2f", symbol, val)
    }
}

/// Token 采集口径标识（透明区分直连 CLI 精确分项与 Lody 上下文用量，绝不混算）
public enum TokenMetricKind: String, Codable, Hashable, Sendable {
    /// 直连本地 CLI（Claude / Antigravity / Codex）返回的精确 Token 分项
    case exact
    /// Lody 异步会话完成后回拉的上下文窗口用量（contextWindowUsage.used）
    case contextWindow
    /// Lody 刚派发尚未完成同步
    case pendingSync

    public var badgeLabel: String {
        switch self {
        case .exact: return "精确"
        case .contextWindow: return "上下文"
        case .pendingSync: return "待同步"
        }
    }
}

public struct AgentUsageMetrics: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public var thinkingTokens: Int
    public var totalTokens: Int
    /// Claude Code 等直接返回的官方费用（USD），存在时优先采用
    public var reportedCostUSD: Double?
    public var durationSeconds: Double?
    public var metricKind: TokenMetricKind

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        thinkingTokens: Int = 0,
        totalTokens: Int? = nil,
        reportedCostUSD: Double? = nil,
        durationSeconds: Double? = nil,
        metricKind: TokenMetricKind = .exact
    ) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheCreationTokens = max(0, cacheCreationTokens)
        self.thinkingTokens = max(0, thinkingTokens)
        let computedTotal = max(0, inputTokens) + max(0, outputTokens) + max(0, cacheReadTokens) + max(0, cacheCreationTokens)
        if let explicit = totalTokens, explicit > 0 {
            self.totalTokens = explicit
        } else {
            self.totalTokens = computedTotal
        }
        self.reportedCostUSD = reportedCostUSD
        self.durationSeconds = durationSeconds
        self.metricKind = metricKind
    }

    /// 提示词缓存命中率（仅在精确分项且存在输入/缓存数据时有值）
    public var cacheHitRate: Double? {
        guard metricKind == .exact else { return nil }
        let denom = inputTokens + cacheReadTokens + cacheCreationTokens
        guard denom > 0, cacheReadTokens > 0 else { return nil }
        return Double(cacheReadTokens) / Double(denom)
    }
}

public struct ReviewUsageRun: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let itemID: String
    public let platform: PlatformKind
    public let scope: String
    public let externalRef: String
    public let title: String
    public let reviewRound: Int
    public let continuityMode: ReviewContinuityMode
    public let engine: AgentEngine
    public var lodyAgentName: String?
    public var model: String
    public let effort: ReasoningEffort
    public let sessionID: String?
    public let isCouncilSecondary: Bool
    public var usage: AgentUsageMetrics
    public var estimatedCostUSD: Double
    public let succeeded: Bool
    public let createdAt: Date
    public var syncedAt: Date?

    public init(
        id: String = UUID().uuidString,
        itemID: String,
        platform: PlatformKind,
        scope: String,
        externalRef: String,
        title: String,
        reviewRound: Int = 1,
        continuityMode: ReviewContinuityMode = .freshSessionFull,
        engine: AgentEngine,
        lodyAgentName: String? = nil,
        model: String,
        effort: ReasoningEffort,
        sessionID: String? = nil,
        isCouncilSecondary: Bool = false,
        usage: AgentUsageMetrics,
        estimatedCostUSD: Double? = nil,
        succeeded: Bool = true,
        createdAt: Date = Date(),
        syncedAt: Date? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.platform = platform
        self.scope = scope
        self.externalRef = externalRef
        self.title = title
        self.reviewRound = reviewRound
        self.continuityMode = continuityMode
        self.engine = engine
        self.lodyAgentName = lodyAgentName
        self.model = model
        self.effort = effort
        self.sessionID = sessionID
        self.isCouncilSecondary = isCouncilSecondary
        self.usage = usage
        self.estimatedCostUSD = estimatedCostUSD ?? UsageCostEstimator.estimateUSD(model: model, engine: engine, usage: usage)
        self.succeeded = succeeded
        self.createdAt = createdAt
        self.syncedAt = syncedAt
    }

    public var displayContextTag: String {
        externalRef.isEmpty ? scope : "\(scope) \(externalRef)"
    }

    public var displayModelKey: String {
        if engine == .lody {
            let cleanModel = (model.isEmpty || model == "default") ? (lodyAgentName ?? "Workspace 默认") : model
            return "Lody · \(cleanModel)"
        }
        return model.isEmpty ? engine.displayName : model
    }
}

public enum UsageTimeRange: String, CaseIterable, Identifiable, Sendable {
    case today = "今日"
    case last7Days = "7 天"
    case last30Days = "30 天"
    case allTime = "全部"

    public var id: String { rawValue }

    public func cutoffDate(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .last7Days:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .last30Days:
            return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        case .allTime:
            return nil
        }
    }
}

// MARK: - 参考 API 价值估算器（对标 Magpie List Price 建模）

public enum UsageCostEstimator {
    private struct ModelRate {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheReadPerMillion: Double
    }

    public static func estimateUSD(model: String, engine: AgentEngine, usage: AgentUsageMetrics) -> Double {
        if let reported = usage.reportedCostUSD, reported > 0 {
            return reported
        }
        guard usage.totalTokens > 0 else { return 0 }

        let rate = rateFor(model: model, engine: engine)

        if usage.metricKind == .contextWindow {
            // Lody 上下文窗口总量不含精确输入/输出拆分，按典型 PR 审查 85% 输入 + 15% 输出保守估算参考 API 价值
            let estInput = Double(usage.totalTokens) * 0.85
            let estOutput = Double(usage.totalTokens) * 0.15
            return (estInput * rate.inputPerMillion + estOutput * rate.outputPerMillion) / 1_000_000.0
        }

        let inputCost = Double(usage.inputTokens) * rate.inputPerMillion
        let cacheCreateCost = Double(usage.cacheCreationTokens) * rate.inputPerMillion * 1.25
        let cacheReadCost = Double(usage.cacheReadTokens) * rate.cacheReadPerMillion
        let outputCost = Double(usage.outputTokens) * rate.outputPerMillion
        return (inputCost + cacheCreateCost + cacheReadCost + outputCost) / 1_000_000.0
    }

    private static func rateFor(model: String, engine: AgentEngine) -> ModelRate {
        let lower = model.lowercased()
        if lower.contains("opus") || lower.contains("fable") {
            return ModelRate(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.5)
        }
        if lower.contains("haiku") {
            return ModelRate(inputPerMillion: 0.8, outputPerMillion: 4.0, cacheReadPerMillion: 0.08)
        }
        if lower.contains("sonnet") {
            return ModelRate(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3)
        }
        if lower.contains("flash") || lower.contains("luna") {
            return ModelRate(inputPerMillion: 0.5, outputPerMillion: 3.0, cacheReadPerMillion: 0.05)
        }
        if lower.contains("gemini") || lower.contains("neon") || lower.contains("carbon") || lower.contains("argon") {
            return ModelRate(inputPerMillion: 2.5, outputPerMillion: 15.0, cacheReadPerMillion: 0.25)
        }
        if lower.contains("astra") || lower.contains("o3") {
            return ModelRate(inputPerMillion: 5.0, outputPerMillion: 20.0, cacheReadPerMillion: 0.5)
        }
        if lower.contains("codex") || lower.contains("sol") || lower.contains("gpt") || lower.contains("terra") {
            return ModelRate(inputPerMillion: 2.5, outputPerMillion: 10.0, cacheReadPerMillion: 0.25)
        }
        switch engine {
        case .claudeCode:
            return ModelRate(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.3)
        case .codex:
            return ModelRate(inputPerMillion: 2.5, outputPerMillion: 10.0, cacheReadPerMillion: 0.25)
        case .antigravity, .lody:
            return ModelRate(inputPerMillion: 2.5, outputPerMillion: 15.0, cacheReadPerMillion: 0.25)
        }
    }
}

// MARK: - 统计聚合与 CSV 导出

public struct ModelUsageBucket: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let engine: AgentEngine
    public let runCount: Int
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let thinkingTokens: Int
    public let estimatedCostUSD: Double
    public let metricKind: TokenMetricKind
}

public struct ScopeUsageBucket: Identifiable, Hashable, Sendable {
    public let id: String
    public let scope: String
    public let runCount: Int
    public let totalTokens: Int
    public let estimatedCostUSD: Double
}

public struct DailyUsagePoint: Identifiable, Hashable, Sendable {
    public let id: String
    public let day: Date
    public let engine: AgentEngine
    public let runCount: Int
    public let totalTokens: Int
    public let estimatedCostUSD: Double
}

public struct UsageSummaryReport: Sendable {
    public let filteredRuns: [ReviewUsageRun]
    public let totalRuns: Int
    public let uniqueReviewTargetCount: Int
    public let reReviewCount: Int
    public let totalTokens: Int
    public let exactTokensTotal: Int
    public let contextWindowTokensTotal: Int
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalCacheReadTokens: Int
    public let totalThinkingTokens: Int
    public let cacheHitRate: Double?
    public let totalEstimatedCostUSD: Double
    public let averageDurationSeconds: Double?
    public let pendingSyncLodyCount: Int
    public let byModel: [ModelUsageBucket]
    public let byScope: [ScopeUsageBucket]
    public let dailyTrend: [DailyUsagePoint]
}

public enum UsageAggregator {
    public static func aggregate(
        runs: [ReviewUsageRun],
        range: UsageTimeRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageSummaryReport {
        let cutoff = range.cutoffDate(from: now, calendar: calendar)
        let filtered = runs.filter { run in
            guard let cutoff else { return true }
            return run.createdAt >= cutoff
        }
        .sorted { $0.createdAt > $1.createdAt }

        var uniqueTargets: Set<String> = []
        var reReviewCount = 0
        var totalTokens = 0
        var exactTokens = 0
        var contextTokens = 0
        var totalIn = 0
        var totalOut = 0
        var totalCacheRead = 0
        var totalCacheCreate = 0
        var totalThinking = 0
        var totalCost = 0.0
        var durationSum = 0.0
        var durationCount = 0
        var pendingLody = 0

        struct ModelAcc {
            var displayName: String
            var engine: AgentEngine
            var runs = 0
            var total = 0
            var input = 0
            var output = 0
            var cacheRead = 0
            var thinking = 0
            var cost = 0.0
            var metricKind: TokenMetricKind
        }
        var modelMap: [String: ModelAcc] = [:]

        struct ScopeAcc {
            var runs = 0
            var total = 0
            var cost = 0.0
        }
        var scopeMap: [String: ScopeAcc] = [:]

        struct DayKey: Hashable {
            let day: Date
            let engine: AgentEngine
        }
        struct DayAcc {
            var runs = 0
            var total = 0
            var cost = 0.0
        }
        var dayMap: [DayKey: DayAcc] = [:]

        for run in filtered {
            uniqueTargets.insert("\(run.platform.rawValue):\(run.scope.lowercased())#\(run.externalRef.lowercased())")
            if run.reviewRound > 1 {
                reReviewCount += 1
            }
            totalTokens += run.usage.totalTokens
            switch run.usage.metricKind {
            case .exact:
                exactTokens += run.usage.totalTokens
            case .contextWindow:
                contextTokens += run.usage.totalTokens
            case .pendingSync:
                if run.engine == .lody && run.sessionID != nil {
                    pendingLody += 1
                }
            }
            totalIn += run.usage.inputTokens
            totalOut += run.usage.outputTokens
            totalCacheRead += run.usage.cacheReadTokens
            totalCacheCreate += run.usage.cacheCreationTokens
            totalThinking += run.usage.thinkingTokens
            totalCost += run.estimatedCostUSD
            if let dur = run.usage.durationSeconds, dur > 0 {
                durationSum += dur
                durationCount += 1
            }

            let mKey = "\(run.engine.rawValue)|\(run.displayModelKey)"
            var mAcc = modelMap[mKey] ?? ModelAcc(
                displayName: run.displayModelKey,
                engine: run.engine,
                metricKind: run.usage.metricKind
            )
            mAcc.runs += 1
            mAcc.total += run.usage.totalTokens
            mAcc.input += run.usage.inputTokens
            mAcc.output += run.usage.outputTokens
            mAcc.cacheRead += run.usage.cacheReadTokens
            mAcc.thinking += run.usage.thinkingTokens
            mAcc.cost += run.estimatedCostUSD
            if mAcc.metricKind == .pendingSync && run.usage.metricKind != .pendingSync {
                mAcc.metricKind = run.usage.metricKind
            }
            modelMap[mKey] = mAcc

            var sAcc = scopeMap[run.scope] ?? ScopeAcc()
            sAcc.runs += 1
            sAcc.total += run.usage.totalTokens
            sAcc.cost += run.estimatedCostUSD
            scopeMap[run.scope] = sAcc

            let dayStart = calendar.startOfDay(for: run.createdAt)
            let dKey = DayKey(day: dayStart, engine: run.engine)
            var dAcc = dayMap[dKey] ?? DayAcc()
            dAcc.runs += 1
            dAcc.total += run.usage.totalTokens
            dAcc.cost += run.estimatedCostUSD
            dayMap[dKey] = dAcc
        }

        let cacheDenom = totalIn + totalCacheRead + totalCacheCreate
        let cacheRate: Double? = (cacheDenom > 0 && totalCacheRead > 0)
            ? (Double(totalCacheRead) / Double(cacheDenom))
            : nil

        let byModel = modelMap.map { key, acc in
            ModelUsageBucket(
                id: key,
                displayName: acc.displayName,
                engine: acc.engine,
                runCount: acc.runs,
                totalTokens: acc.total,
                inputTokens: acc.input,
                outputTokens: acc.output,
                cacheReadTokens: acc.cacheRead,
                thinkingTokens: acc.thinking,
                estimatedCostUSD: acc.cost,
                metricKind: acc.metricKind
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.runCount > rhs.runCount
        }

        let byScope = scopeMap.map { scope, acc in
            ScopeUsageBucket(
                id: scope,
                scope: scope,
                runCount: acc.runs,
                totalTokens: acc.total,
                estimatedCostUSD: acc.cost
            )
        }
        .sorted { lhs, rhs in
            if lhs.runCount != rhs.runCount { return lhs.runCount > rhs.runCount }
            return lhs.totalTokens > rhs.totalTokens
        }

        let dailyTrend = dayMap.map { key, acc in
            DailyUsagePoint(
                id: "\(key.day.timeIntervalSince1970)-\(key.engine.rawValue)",
                day: key.day,
                engine: key.engine,
                runCount: acc.runs,
                totalTokens: acc.total,
                estimatedCostUSD: acc.cost
            )
        }
        .sorted { $0.day < $1.day }

        return UsageSummaryReport(
            filteredRuns: filtered,
            totalRuns: filtered.count,
            uniqueReviewTargetCount: uniqueTargets.count,
            reReviewCount: reReviewCount,
            totalTokens: totalTokens,
            exactTokensTotal: exactTokens,
            contextWindowTokensTotal: contextTokens,
            totalInputTokens: totalIn,
            totalOutputTokens: totalOut,
            totalCacheReadTokens: totalCacheRead,
            totalThinkingTokens: totalThinking,
            cacheHitRate: cacheRate,
            totalEstimatedCostUSD: totalCost,
            averageDurationSeconds: durationCount > 0 ? (durationSum / Double(durationCount)) : nil,
            pendingSyncLodyCount: pendingLody,
            byModel: byModel,
            byScope: byScope,
            dailyTrend: dailyTrend
        )
    }

    public static func formatCompactTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        }
        if count >= 10_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.2fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    public static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)m \(secs)s"
    }

    public static func exportCSV(runs: [ReviewUsageRun], currency: UsageCurrency) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = [
            "timestamp,platform,scope,ref,round,engine,model,effort,metric_kind,total_tokens,input_tokens,output_tokens,cache_read_tokens,thinking_tokens,duration_s,estimated_cost_\(currency.rawValue),session_id"
        ]
        for r in runs {
            let costVal = String(format: "%.4f", currency.convert(usd: r.estimatedCostUSD))
            let dur = r.usage.durationSeconds.map { String(format: "%.1f", $0) } ?? ""
            let row = [
                iso.string(from: r.createdAt),
                r.platform.rawValue,
                escapeCSV(r.scope),
                escapeCSV(r.externalRef),
                "\(r.reviewRound)",
                r.engine.rawValue,
                escapeCSV(r.displayModelKey),
                r.effort.rawValue,
                r.usage.metricKind.rawValue,
                "\(r.usage.totalTokens)",
                "\(r.usage.inputTokens)",
                "\(r.usage.outputTokens)",
                "\(r.usage.cacheReadTokens)",
                "\(r.usage.thinkingTokens)",
                dur,
                costVal,
                r.sessionID ?? ""
            ].joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }

    private static func escapeCSV(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }
}
