import Foundation
import Testing
@testable import CollabDockApp
@testable import CollabDockCore

/// SPEC（实现前为红）：App 层把语言设置落到实处（issue #4）。
/// - 改界面语言：持久化，并通过系统集成写入 / 移除 App 级 `AppleLanguages` 覆盖（重启后生效）；
/// - 审查语言：确认运行时按「审查语言 → 界面语言」解析后交给交付环节。
@MainActor
@Suite("SPEC — App applies the UI language and forwards the review language (issue #4)", .serialized)
struct LanguageSpecTests {
    private func makeCoordinator(settings: AppSettings = AppSettings()) -> (AppCoordinator, InMemorySettingsStore, RecordingSystemIntegration, FakeConnectorFactory) {
        let store = InMemorySettingsStore(settings)
        let system = RecordingSystemIntegration()
        let connectors = FakeConnectorFactory()
        let coordinator = AppCoordinator(
            autoStart: false,
            settingsStore: store,
            detector: StaticEnvironment(),
            taskStore: MemoryTaskStore(),
            connectorFactory: connectors,
            backendFactory: QueueBackendFactory([ScriptedBackend()]),
            systemIntegration: system,
            clock: FixedClock()
        )
        return (coordinator, store, system, connectors)
    }

    @Test("Choosing a UI language persists it and applies the AppleLanguages override; System removes the override")
    func uiLanguageIsAppliedAndPersisted() {
        let (coordinator, store, system, _) = makeCoordinator()

        coordinator.settings.appLanguage = .en
        #expect(store.savedSettings.last?.appLanguage == .en)
        #expect(system.languageOverrides.last == .some(["en"]))

        coordinator.settings.appLanguage = .zhHans
        #expect(system.languageOverrides.last == .some(["zh-Hans"]))

        coordinator.settings.appLanguage = .system
        #expect(store.savedSettings.last?.appLanguage == .system)
        #expect(system.languageOverrides.last == .some(nil))
    }

    @Test("Changing an unrelated setting does not re-apply the UI language")
    func unrelatedSettingDoesNotTouchLanguage() {
        let (coordinator, _, system, _) = makeCoordinator()
        let before = system.languageOverrides.count
        coordinator.settings.notificationsEnabled = false
        #expect(system.languageOverrides.count == before)
    }

    @Test("Confirm & run delivers in the review language, resolved against the UI language when set to follow it")
    func reviewLanguageReachesDelivery() async throws {
        let cases: [(AppLanguage, ReviewLanguage, ResolvedLanguage)] = [
            (.zhHans, .en, .en),
            (.en, .zhHans, .zhHans),
            (.zhHans, .followUI, .zhHans),
            (.en, .followUI, .en),
        ]
        for (ui, review, expected) in cases {
            var settings = AppSettings()
            settings.appLanguage = ui
            settings.reviewLanguage = review
            let (coordinator, _, _, connectors) = makeCoordinator(settings: settings)
            let pr = AppFixtures.prItem()
            coordinator.items = [pr]

            let task = coordinator.confirmAndRun(itemID: pr.id, plan: ExecutionPlan(engine: .codex, model: "gpt-5.3-codex"))
            await task?.value

            let context = try #require(connectors.sink.contexts.first, "nothing was delivered for ui=\(ui) review=\(review)")
            #expect(context.language == expected, "ui=\(ui) review=\(review)")
        }
    }
}
