import Foundation
import Testing
@testable import CollabDockApp
@testable import CollabDockCore

/// SPEC（实现前为红）：卡片上的「停止」「停止并换个设置重来」以及「已自动开始」通知上的「停止」按钮，
/// 都要真正取消 Lody 里正在进行的那一轮，而不只是 CollabDock 停止跟踪。
/// 通知上的「打开 Lody」按钮打开对应会话。
@MainActor
@Suite("SPEC — stop cancels the running Lody turn; notification actions", .serialized)
struct StopCancelsLodySessionSpecTests {
    private struct Harness {
        let system: RecordingSystemIntegration
        let backends: QueueBackendFactory
        let coordinator: AppCoordinator

        @MainActor
        init() {
            system = RecordingSystemIntegration()
            backends = QueueBackendFactory([ScriptedBackend()])
            coordinator = AppCoordinator(
                autoStart: false,
                settingsStore: InMemorySettingsStore(),
                detector: StaticEnvironment(),
                taskStore: MemoryTaskStore(),
                connectorFactory: FakeConnectorFactory(),
                backendFactory: backends,
                systemIntegration: system,
                clock: FixedClock()
            )
        }
    }

    /// 已派发、Lody 里还在跑的卡片
    private func dispatched(number: Int = 7, remote: RemoteSessionStatus? = .running) -> CollaborationItem {
        var item = AppFixtures.prItem(number: number, sha: "abc1234", status: .draftReady)
        item.sessionHandle = AgentSessionHandle(engine: .lody, sessionID: "lody-sess-1", workspacePath: "/tmp/collabdock-app-test-wt", launchMode: .nativeBackgroundSession)
        item.sessionID = "lody-sess-1"
        item.remoteSessionStatus = remote
        return item
    }

    @Test("Stop on a running Lody review cancels that Lody turn and puts the card back to pending")
    func stopCancelsTheTurn() async {
        let h = Harness()
        let item = dispatched()
        h.coordinator.items = [item]

        h.coordinator.cancelRunningItem(id: item.id)

        #expect(await eventually { h.backends.canceller.cancelled == ["lody-sess-1"] })
        #expect(h.coordinator.items.first?.status == .pendingConfirmation)
    }

    @Test("Stop & reconfigure also cancels the Lody turn before returning to the confirmation card")
    func stopAndReconfigureCancelsTheTurn() async {
        let h = Harness()
        let item = dispatched()
        h.coordinator.items = [item]

        h.coordinator.stopAndReconfigureItem(id: item.id)

        #expect(await eventually { h.backends.canceller.cancelled == ["lody-sess-1"] })
        #expect(h.coordinator.items.first?.status == .pendingConfirmation)
        #expect(h.coordinator.items.first?.sessionHandle == nil)
    }

    @Test("Nothing to cancel: no Lody call when there is no session yet, or the Lody session already finished")
    func noCancelWithoutARunningSession() async throws {
        let h = Harness()
        let notDispatched = AppFixtures.prItem(number: 8, sha: "def5678", status: .running)
        let finished = dispatched(number: 9, remote: .completed)
        h.coordinator.items = [notDispatched, finished]

        h.coordinator.cancelRunningItem(id: notDispatched.id)
        h.coordinator.stopAndReconfigureItem(id: finished.id)
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(h.backends.canceller.cancelled.isEmpty)
    }

    @Test("If Lody refuses to cancel, the card still goes back to pending and the user is told")
    func cancelFailureIsReported() async {
        let h = Harness()
        h.backends.canceller.error = NSError(domain: "lody", code: 1, userInfo: [NSLocalizedDescriptionKey: "Session has no active turn"])
        let item = dispatched()
        h.coordinator.items = [item]

        h.coordinator.cancelRunningItem(id: item.id)

        #expect(h.coordinator.items.first?.status == .pendingConfirmation)
        #expect(await eventually { h.coordinator.lastSystemNotice?.contains("Session has no active turn") == true })
    }

    @Test("The notification's Stop button cancels the Lody turn like the card's Stop")
    func notificationStop() async {
        let h = Harness()
        let item = dispatched()
        h.coordinator.items = [item]

        h.system.onNotificationAction?(item.id, .stop)

        #expect(await eventually { h.backends.canceller.cancelled == ["lody-sess-1"] })
        #expect(h.coordinator.items.first?.status == .pendingConfirmation)
    }

    @Test("The notification's Open Lody button opens that Lody session")
    func notificationOpenLody() {
        let h = Harness()
        let item = dispatched()
        h.coordinator.items = [item]

        h.system.onNotificationAction?(item.id, .openLody)

        #expect(h.system.handoffs == ["lody-sess-1"])
        #expect(h.backends.canceller.cancelled.isEmpty)
    }

    @Test("Notification actions are exactly Open Lody and Stop")
    func actionSet() {
        #expect(Set(NotificationAction.allCases) == [.openLody, .stop])
    }
}
