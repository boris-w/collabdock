import Foundation
import Testing
@testable import CollabDockApp
@testable import CollabDockCore

/// SPEC（实现前为红）：App 层的自动开始审查与开始时的 👀。
///
/// - 只有同步新进来的请求会自动开始；手动「+」导入永远打开确认卡片；
/// - 自动开始用 `defaultPlan(for:)`，卡片标记 `wasAutoStarted` 并落盘；
/// - 通知：自动开始的请求发「已自动开始」（可关），不再另发「新请求」通知；
/// - 失败：卡片失败并带错误信息，同一错误连续出现只通知一次；
/// - 暂停：期间进来的请求留在「待你确认」，恢复后不补派；
/// - 👀：开始审查（手动或自动）派发成功后加一次，开关关掉就不加。
@MainActor
@Suite("SPEC — App auto-starts eligible requests and marks review start with 👀", .serialized)
struct AutoStartAppSpecTests {
    @MainActor
    struct Harness {
        let store: MemoryTaskStore
        let connectors: FakeConnectorFactory
        let backend: ScriptedBackend
        let system: RecordingSystemIntegration
        let coordinator: AppCoordinator

        init(settings: AppSettings, candidates: [PolledCollaborationCandidate] = [], fetched: CollaborationItem? = nil) {
            store = MemoryTaskStore()
            connectors = FakeConnectorFactory(
                source: ScriptedSource(.success(PollBatch(candidates: candidates))),
                fetcher: ScriptedFetcher(item: fetched)
            )
            backend = ScriptedBackend()
            system = RecordingSystemIntegration()
            coordinator = AppCoordinator(
                autoStart: false,
                settingsStore: InMemorySettingsStore(settings),
                detector: StaticEnvironment(),
                taskStore: store,
                connectorFactory: connectors,
                backendFactory: QueueBackendFactory([backend]),
                systemIntegration: system,
                clock: FixedClock()
            )
        }

        func item(_ id: String) -> CollaborationItem? { coordinator.items.first { $0.id == id } }
    }

    private func autoOn(_ tweak: (inout AutoStartSettings) -> Void = { _ in }) -> AppSettings {
        var s = AppSettings()
        s.autoStart.isEnabled = true
        tweak(&s.autoStart)
        return s
    }

    // MARK: auto-start

    @Test("Off by default: a synced request waits for confirmation and gets the usual notification")
    func offByDefault() async {
        let c = AppFixtures.candidate()
        let h = Harness(settings: AppSettings(), candidates: [c])

        await h.coordinator.syncNow()

        #expect(h.item(c.item.id)?.status == .pendingConfirmation)
        #expect(h.backend.executeCount == 0)
        #expect(h.system.incoming == [c.item.id])
        #expect(h.system.autoStarted.isEmpty)
    }

    @Test("On: a synced review request starts by itself with the default plan, is marked and saved as auto-started, and posts the auto-start notification instead")
    func syncAutoStarts() async throws {
        let c = AppFixtures.candidate()
        let h = Harness(settings: autoOn(), candidates: [c])

        await h.coordinator.syncNow()

        #expect(await eventually { h.item(c.item.id)?.status == .draftReady })
        #expect(h.backend.executeCount == 1)
        let request = try #require(h.backend.requests.first)
        #expect(request.plan.engine == .lody)
        #expect(request.item.id == c.item.id)
        #expect(h.item(c.item.id)?.wasAutoStarted == true)
        #expect(await eventually { await h.store.items[c.item.id]?.wasAutoStarted == true })
        #expect(h.system.autoStarted == [c.item.id])
        #expect(h.system.incoming.isEmpty, "an auto-started request does not also get the new-request notification")
    }

    @Test("On with the start notification turned off: it still starts, silently")
    func silentAutoStart() async {
        let c = AppFixtures.candidate()
        let h = Harness(settings: autoOn { $0.notifyOnStart = false }, candidates: [c])

        await h.coordinator.syncNow()

        #expect(await eventually { h.item(c.item.id)?.status == .draftReady })
        #expect(h.system.autoStarted.isEmpty)
        #expect(h.system.incoming.isEmpty)
    }

    @Test("A trigger kind that is not selected waits for confirmation as before")
    func unselectedTriggerWaits() async {
        let c = AppFixtures.candidate(repository: "acme/backend", number: 9, trigger: .assigned)
        let h = Harness(settings: autoOn(), candidates: [c])

        await h.coordinator.syncNow()

        #expect(h.item(c.item.id)?.status == .pendingConfirmation)
        #expect(h.backend.executeCount == 0)
        #expect(h.system.incoming == [c.item.id])
    }

    @Test("A repository outside the auto-start list waits for confirmation")
    func repositoryOutsideListWaits() async {
        let inside = AppFixtures.candidate(repository: "acme/web-console", number: 3, trigger: .reviewRequested)
        let outside = AppFixtures.candidate(repository: "acme/backend", number: 4, trigger: .reviewRequested)
        let h = Harness(settings: autoOn { $0.repositoryAllowlist = ["acme/web-*"] }, candidates: [inside, outside])

        await h.coordinator.syncNow()

        #expect(await eventually { h.item(inside.item.id)?.status == .draftReady })
        #expect(h.item(outside.item.id)?.status == .pendingConfirmation)
        #expect(h.backend.executeCount == 1)
    }

    @Test("Paused: requests stay pending, and resuming does not back-fill them")
    func pausedDoesNotStartOrBackfill() async throws {
        let c = AppFixtures.candidate()
        let h = Harness(settings: autoOn { $0.isPaused = true }, candidates: [c])

        await h.coordinator.syncNow()
        #expect(h.item(c.item.id)?.status == .pendingConfirmation)

        h.coordinator.settings.autoStart.isPaused = false
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(h.backend.executeCount == 0)
        #expect(h.item(c.item.id)?.status == .pendingConfirmation)
    }

    @Test("A manually imported PR never auto-starts; it opens the confirmation card")
    func manualImportNeverAutoStarts() async throws {
        let pr = AppFixtures.prItem(number: 12, sha: "fffffff")
        let h = Harness(settings: autoOn(), fetched: pr)

        let result = await h.coordinator.importPullRequest(reference: "acme/backend#12")

        let imported = try #require(try? result.get())
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(h.backend.executeCount == 0)
        #expect(h.item(imported.id)?.status == .pendingConfirmation)
        #expect(h.item(imported.id)?.wasAutoStarted == false)
    }

    @Test("A failed auto-start leaves the card failed with the error; the same error is announced only once")
    func failureDedupe() async throws {
        let first = AppFixtures.candidate(repository: "acme/backend", number: 21, trigger: .reviewRequested)
        let second = AppFixtures.candidate(repository: "acme/backend", number: 22, trigger: .reviewRequested)
        let h = Harness(settings: autoOn(), candidates: [first, second])
        h.backend.result = .failure(AgentRunnerError.processFailed(exitCode: 1, stderr: "Lody CLI login expired"))

        await h.coordinator.syncNow()

        #expect(await eventually {
            h.item(first.item.id)?.status == .failed && h.item(second.item.id)?.status == .failed
        })
        #expect(h.item(first.item.id)?.wasAutoStarted == true)
        #expect(h.item(first.item.id)?.errorMessage?.isEmpty == false)
        #expect(h.system.autoStartFailures.count == 1, "\(h.system.autoStartFailures.map(\.message))")

        // A different error is news again
        let third = AppFixtures.candidate(repository: "acme/backend", number: 23, trigger: .reviewRequested)
        h.connectors.source.result = .success(PollBatch(candidates: [third]))
        h.backend.result = .failure(AgentRunnerError.processFailed(exitCode: 2, stderr: "network unreachable"))
        await h.coordinator.syncNow()

        #expect(await eventually { h.item(third.item.id)?.status == .failed })
        #expect(h.system.autoStartFailures.count == 2)
    }

    // MARK: 👀

    @Test("Starting a review by hand adds 👀 once the session is dispatched (switch on by default)")
    func manualStartReacts() async {
        let pr = AppFixtures.prItem()
        let h = Harness(settings: AppSettings())
        h.coordinator.items = [pr]

        let task = h.coordinator.confirmAndRun(itemID: pr.id, plan: h.coordinator.defaultPlan(for: pr))
        await task?.value

        #expect(h.item(pr.id)?.status == .draftReady)
        #expect(await eventually { h.connectors.reactor.calls == [pr.id] })
    }

    @Test("With the 👀 switch off nothing is added")
    func reactionSwitchOff() async throws {
        var s = AppSettings()
        s.markReviewStartWithReaction = false
        let pr = AppFixtures.prItem()
        let h = Harness(settings: s)
        h.coordinator.items = [pr]

        let task = h.coordinator.confirmAndRun(itemID: pr.id, plan: h.coordinator.defaultPlan(for: pr))
        await task?.value
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(h.item(pr.id)?.status == .draftReady)
        #expect(h.connectors.reactor.calls.isEmpty)
    }

    @Test("Auto-started reviews add 👀 too")
    func autoStartReacts() async {
        let c = AppFixtures.candidate()
        let h = Harness(settings: autoOn(), candidates: [c])

        await h.coordinator.syncNow()

        #expect(await eventually { h.connectors.reactor.calls == [c.item.id] })
    }
}
