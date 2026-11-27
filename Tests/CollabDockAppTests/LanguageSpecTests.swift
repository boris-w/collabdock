import Foundation
import Testing
@testable import CollabDockApp
@testable import CollabDockCore

/// App 层把界面语言落到实处（issue #4）：改界面语言时持久化，并通过系统集成写入 / 移除 App 级 `AppleLanguages` 覆盖（重启后生效）。
/// 审查语言随 CollabDock 自写 GitHub 文案一起移除（Lody-only）。
@MainActor
@Suite("App applies the UI language (issue #4)", .serialized)
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
}
