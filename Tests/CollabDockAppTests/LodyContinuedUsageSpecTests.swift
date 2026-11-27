import Foundation
import Testing
@testable import CollabDockApp
@testable import CollabDockCore

/// SPEC（实现前为红）：续聊同一个 Lody 会话做复审时，用量账本只记本轮新增的上下文，不重复计入上一轮。
///
/// `lody session show` 的 `contextWindowUsage.used` 是整个会话当前的上下文大小（真实案例：第 1 轮 380.6K、第 2 轮结束时 462.4K）。
/// 现状把 462.4K 原样记给第 2 轮，统计面板里两轮合计 843K，第 1 轮被重复计算。
@MainActor
@Suite("SPEC — usage ledger for continued Lody sessions", .serialized)
struct LodyContinuedUsageSpecTests {
    static let sessionID = "lody-sess-1"
    static let roundOneAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let roundTwoAt = roundOneAt.addingTimeInterval(2 * 3600)

    struct LodyEnvironment: EnvironmentDetecting {
        var snapshot: EnvironmentDetector.LodySessionUsageSnapshot

        func detectAll(customPaths: [String: String], manualGitHubPAT: String?) async -> EnvironmentSnapshot {
            var env = StaticEnvironment().snapshot
            env = EnvironmentSnapshot(
                resolvedPATH: env.resolvedPATH, git: env.git, gh: env.gh,
                engines: env.engines.merging([.lody: CLIProbeStatus(name: "lody", isInstalled: true, executablePath: "/usr/local/bin/lody")]) { a, _ in a },
                githubAuth: env.githubAuth, discoveredModels: env.discoveredModels
            )
            return env
        }
        func resolveGitHubToken(ghExecutablePath: String?, manualPAT: String?) async -> String? { nil }
        func fetchLodyCatalog(lodyProbe: CLIProbeStatus, workspace: String?, resolvedPATH: String?) async -> LodyCatalogSnapshot? { nil }
        func fetchLodySessionUsage(lodyProbe: CLIProbeStatus, sessionID: String, workspace: String?, resolvedPATH: String?) async -> EnvironmentDetector.LodySessionUsageSnapshot? {
            sessionID == snapshot.sessionID ? snapshot : nil
        }
    }

    private func run(_ id: String, round: Int, at date: Date, tokens: Int?, synced: Bool) -> ReviewUsageRun {
        ReviewUsageRun(
            id: id,
            itemID: "github:acme/web#4800:round\(round)",
            platform: .github,
            scope: "acme/web",
            externalRef: "#4800",
            title: "fix: cursor paging",
            reviewRound: round,
            continuityMode: round > 1 ? .continueSessionIncremental : .freshSessionFull,
            engine: .lody,
            model: "gemini-4-neon",
            effort: .high,
            sessionID: Self.sessionID,
            usage: tokens.map { AgentUsageMetrics(totalTokens: $0, durationSeconds: 739, metricKind: .contextWindow) }
                ?? AgentUsageMetrics(metricKind: .pendingSync),
            createdAt: date,
            syncedAt: synced ? date.addingTimeInterval(739) : nil
        )
    }

    private func coordinator(contextNow: Int) async -> AppCoordinator {
        let snap = EnvironmentDetector.LodySessionUsageSnapshot(
            sessionID: Self.sessionID,
            isSettledIdle: true,
            contextUsedTokens: contextNow,
            modelID: "gemini-4-neon",
            modelName: "Gemini 4 Neon",
            lastMessageAt: Self.roundTwoAt.addingTimeInterval(9 * 60)
        )
        let c = AppCoordinator(
            autoStart: false,
            settingsStore: InMemorySettingsStore(),
            detector: LodyEnvironment(snapshot: snap),
            taskStore: MemoryTaskStore(),
            connectorFactory: FakeConnectorFactory(),
            systemIntegration: RecordingSystemIntegration(),
            clock: FixedClock(Self.roundTwoAt.addingTimeInterval(600))
        )
        await c.refreshEnvironment()
        return c
    }

    @Test("SPEC: round 2 records only the context added since round 1, and its own duration")
    func continuedRoundRecordsGrowthOnly() async throws {
        let c = await coordinator(contextNow: 462_400)
        c.usageRuns = [
            run("run-2", round: 2, at: Self.roundTwoAt, tokens: nil, synced: false),
            run("run-1", round: 1, at: Self.roundOneAt, tokens: 380_600, synced: true)
        ]

        await c.syncPendingLodyUsage()

        let roundTwo = try #require(c.usageRuns.first { $0.id == "run-2" })
        let roundOne = try #require(c.usageRuns.first { $0.id == "run-1" })
        #expect(roundTwo.usage.totalTokens == 81_800, "462.4K − 380.6K")
        let duration = try #require(roundTwo.usage.durationSeconds)
        #expect(duration == 540)
        #expect(roundTwo.syncedAt != nil)
        #expect(roundOne.usage.totalTokens == 380_600)
        #expect(c.usageRuns.reduce(0) { $0 + $1.usage.totalTokens } == 462_400, "session total is counted once")
    }

    @Test("SPEC: if the session context shrank (compaction), the round records the current context instead of a negative delta")
    func compactedContextIsNotNegative() async throws {
        let c = await coordinator(contextNow: 120_000)
        c.usageRuns = [
            run("run-2", round: 2, at: Self.roundTwoAt, tokens: nil, synced: false),
            run("run-1", round: 1, at: Self.roundOneAt, tokens: 380_600, synced: true)
        ]

        await c.syncPendingLodyUsage()

        #expect(c.usageRuns.first { $0.id == "run-2" }?.usage.totalTokens == 120_000)
    }

    @Test("Safety net: the first round of a session records the full context")
    func firstRoundRecordsFullContext() async throws {
        let c = await coordinator(contextNow: 380_600)
        c.usageRuns = [run("run-1", round: 1, at: Self.roundTwoAt, tokens: nil, synced: false)]

        await c.syncPendingLodyUsage()

        #expect(c.usageRuns.first?.usage.totalTokens == 380_600)
    }
}
