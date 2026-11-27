import Foundation
import Testing
@testable import CollabDockCore

@Suite("Usage Analytics, Token Parsing & SQLite Ledger Tests [ITER-014]")
struct UsageAnalyticsTests {
    @Test("Parses exact token usage & cost from Claude, Antigravity (agy), and Codex streaming events")
    func parsesCrossEngineTokenUsage() {
        // 1. Antigravity (agy) nested result.usage
        let agyLine = #"{"event":"result","result":{"conversation_id":"conv_1","status":"SUCCESS","response":"{}","duration_seconds":16.76,"usage":{"input_tokens":17015,"output_tokens":1933,"thinking_tokens":1891,"cache_read_tokens":5000,"total_tokens":18948}}}"#
        let pAgy = AgentStreamParser.parseLine(agyLine)
        #expect(pAgy.isFinalUsage == true)
        #expect(pAgy.usage?.inputTokens == 17015)
        #expect(pAgy.usage?.outputTokens == 1933)
        #expect(pAgy.usage?.thinkingTokens == 1891)
        #expect(pAgy.usage?.cacheReadTokens == 5000)
        #expect(pAgy.usage?.totalTokens == 18948)
        #expect(pAgy.usage?.durationSeconds == 16.76)

        // 2. Claude Code result event with total_cost_usd & cache_read_input_tokens
        let claudeLine = #"{"type":"result","session_id":"sess_c1","duration_ms":24500,"total_cost_usd":0.42,"usage":{"input_tokens":12000,"output_tokens":1800,"cache_read_input_tokens":48000,"cache_creation_input_tokens":2000}}"#
        let pClaude = AgentStreamParser.parseLine(claudeLine)
        #expect(pClaude.isFinalUsage == true)
        #expect(pClaude.usage?.reportedCostUSD == 0.42)
        #expect(pClaude.usage?.cacheReadTokens == 48000)
        #expect(pClaude.usage?.cacheCreationTokens == 2000)
        #expect(pClaude.usage?.durationSeconds == 24.5)
        #expect((pClaude.usage?.cacheHitRate ?? 0) > 0.7)

        // 3. Codex CLI turn.completed usage
        let codexLine = #"{"type":"turn.completed","usage":{"input_tokens":22000,"cached_input_tokens":11000,"output_tokens":2500}}"#
        let pCodex = AgentStreamParser.parseLine(codexLine)
        #expect(pCodex.isFinalUsage == true)
        #expect(pCodex.usage?.inputTokens == 22000)
        #expect(pCodex.usage?.cacheReadTokens == 11000)
        #expect(pCodex.usage?.outputTokens == 2500)
    }

    @Test("Parses Lody session show JSON for async contextWindowUsage and settled idle state")
    func parsesLodySessionShowUsage() {
        let raw = """
        [ws_123] Remote Streams transport attached
        {"ok":true,"session":{"id":"11111111-2222-4333-8444-555555555555","status":{"type":"idle"},"contextWindowUsage":{"size":1048576,"used":84855},"lastModel":{"modelId":"gemini-4-neon","name":"Gemini 4 Neon"},"createdAt":"2026-11-26T11:39:06.892Z","lastMessageAt":1795693422724}}
        """
        let snap = EnvironmentDetector.parseLodySessionShowOutput(raw)
        #expect(snap?.sessionID == "11111111-2222-4333-8444-555555555555")
        #expect(snap?.isSettledIdle == true)
        #expect(snap?.contextUsedTokens == 84855)
        #expect(snap?.modelID == "gemini-4-neon")
        #expect(snap?.modelName == "Gemini 4 Neon")
    }

    @Test("Aggregates usage runs by time range, model, repo, currency, CSV, and persists in SQLite")
    func aggregatesAndPersistsUsageRuns() async throws {
        let now = Date()
        let oldDate = Calendar.current.date(byAdding: .day, value: -15, to: now)!

        let run1 = ReviewUsageRun(
            id: "run-1",
            itemID: "gh:acme/web#1",
            platform: .github,
            scope: "acme/web",
            externalRef: "#1",
            title: "feat: A",
            reviewRound: 1,
            engine: .claudeCode,
            model: "opus",
            effort: .high,
            usage: AgentUsageMetrics(inputTokens: 10_000, outputTokens: 2_000, cacheReadTokens: 30_000, reportedCostUSD: 0.50, durationSeconds: 20, metricKind: .exact),
            createdAt: now
        )
        let run2 = ReviewUsageRun(
            id: "run-2",
            itemID: "gh:acme/web#1:r2",
            platform: .github,
            scope: "acme/web",
            externalRef: "#1",
            title: "feat: A",
            reviewRound: 2,
            continuityMode: .continueSessionIncremental,
            engine: .lody,
            lodyAgentName: "Antigravity",
            model: "Gemini 4 Neon",
            effort: .high,
            sessionID: "ses_1",
            usage: AgentUsageMetrics(totalTokens: 80_000, durationSeconds: 40, metricKind: .contextWindow),
            createdAt: now
        )
        let runOld = ReviewUsageRun(
            id: "run-old",
            itemID: "gh:boris-w/Lody#1",
            platform: .github,
            scope: "boris-w/Lody",
            externalRef: "#1",
            title: "old",
            engine: .codex,
            model: "gpt-6.2-sol",
            effort: .medium,
            usage: AgentUsageMetrics(inputTokens: 5_000, outputTokens: 500, durationSeconds: 10, metricKind: .exact),
            createdAt: oldDate
        )

        let report7d = UsageAggregator.aggregate(runs: [run1, run2, runOld], range: .last7Days, now: now)
        #expect(report7d.totalRuns == 2)
        #expect(report7d.uniqueReviewTargetCount == 1)
        #expect(report7d.reReviewCount == 1)
        #expect(report7d.exactTokensTotal == 42_000)
        #expect(report7d.contextWindowTokensTotal == 80_000)
        #expect(report7d.totalTokens == 122_000)
        #expect(report7d.averageDurationSeconds == 30)
        #expect(report7d.byModel.count == 2)
        #expect(UsageCurrency.usd.format(usd: 0.50) == "$0.50")
        #expect(UsageCurrency.cny.format(usd: 1.0) == "¥7.25")

        let csv = UsageAggregator.exportCSV(runs: report7d.filteredRuns, currency: .cny)
        #expect(csv.contains("estimated_cost_cny"))
        #expect(csv.contains("Lody · Gemini 4 Neon"))

        // SQLite 持久化与更新验证
        let store = try SQLiteTaskStore(databasePath: ":memory:")
        try await store.upsertUsageRun(run1)
        try await store.upsertUsageRun(run2)
        let loaded = try await store.loadAllUsageRuns()
        #expect(loaded.count == 2)
        #expect(loaded.contains(where: { $0.id == "run-2" && $0.usage.totalTokens == 80_000 }))
    }
}
