import Foundation
import Testing
@testable import CollabDockApp
@testable import CollabDockCore

/// SPEC（实现前为红）：App 层只走 Lody。旧数据里残留的直连引擎（建议引擎、上一轮的会话）不会再被选中或续聊。
@MainActor
@Suite("SPEC — the app plans and runs every review on Lody", .serialized)
struct LodyOnlyAppSpecTests {
    private func makeCoordinator(
        settings: AppSettings = AppSettings(),
        backend: ScriptedBackend = ScriptedBackend()
    ) -> (AppCoordinator, InMemorySettingsStore) {
        let store = InMemorySettingsStore(settings)
        let coordinator = AppCoordinator(
            autoStart: false,
            settingsStore: store,
            detector: StaticEnvironment(),
            taskStore: MemoryTaskStore(),
            connectorFactory: FakeConnectorFactory(),
            backendFactory: QueueBackendFactory([backend]),
            systemIntegration: RecordingSystemIntegration(),
            clock: FixedClock()
        )
        return (coordinator, store)
    }

    @Test("The default plan for a new request is Lody")
    func defaultPlanIsLody() {
        let (coordinator, _) = makeCoordinator()
        let plan = coordinator.defaultPlan(for: AppFixtures.prItem())
        #expect(plan.engine == .lody)
        #expect(plan.launchMode == .nativeBackgroundSession)
        #expect(plan.continuityMode == .freshSessionFull)
    }

    @Test("A persisted item that still suggests a direct engine is planned on Lody", arguments: [AgentEngine.claudeCode, .codex, .antigravity])
    func legacySuggestedEngineIsIgnored(engine: AgentEngine) {
        let (coordinator, _) = makeCoordinator()
        var pr = AppFixtures.prItem()
        pr.suggestedEngine = engine
        #expect(coordinator.defaultPlan(for: pr).engine == .lody)
    }

    @Test("A re-review whose previous round ran on a direct engine opens a new Lody session (incremental), never a continue")
    func legacyPreviousRoundStartsFreshLodySession() {
        let (coordinator, _) = makeCoordinator()
        var pr = AppFixtures.prItem(sha: "def5678")
        pr.previousReview = PreviousReviewContext(
            previousItemID: "r1", reviewedHeadSHA: "abc1234", reviewedAt: Date(), engine: .codex, sessionID: "codex-thread-1"
        )
        pr.reviewRound = 2

        let plan = coordinator.defaultPlan(for: pr)

        #expect(plan.engine == .lody)
        #expect(plan.continuityMode == .freshSessionIncremental)
    }

    @Test("Running a plan that names a direct engine dispatches on Lody and remembers Lody as the default")
    func directEnginePlanRunsOnLody() async throws {
        let backend = ScriptedBackend()
        let (coordinator, store) = makeCoordinator(backend: backend)
        let pr = AppFixtures.prItem()
        coordinator.items = [pr]

        await coordinator.confirmAndRun(itemID: pr.id, plan: ExecutionPlan(engine: .codex, model: "gpt-5.3-codex"))?.value

        let request = try #require(backend.requests.first)
        #expect(request.plan.engine == .lody)
        #expect(coordinator.items.first?.status == .draftReady)
        #expect(coordinator.settings.defaultEngine == .lody)
        #expect(store.savedSettings.last?.defaultEngine == .lody)
    }
}
