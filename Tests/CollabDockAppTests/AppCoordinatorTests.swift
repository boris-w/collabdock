import Foundation
import Testing
@testable import CollabDockApp
@testable import CollabDockCore

/// AppCoordinator 的状态流转（安全网）：全部依赖通过构造函数注入假实现，不启动轮询、不访问网络、不调用本机 CLI。
@MainActor
@Suite("AppCoordinator — inbox sync, PR import, execution, cancellation and persistence", .serialized)
struct AppCoordinatorTests {
    struct Harness {
        let settingsStore: InMemorySettingsStore
        let store: MemoryTaskStore
        let connectors: FakeConnectorFactory
        let system: RecordingSystemIntegration
        let coordinator: AppCoordinator

        @MainActor
        init(
            settings: AppSettings = AppSettings(),
            store: MemoryTaskStore = MemoryTaskStore(),
            connectors: FakeConnectorFactory = FakeConnectorFactory(),
            backends: [ScriptedBackend] = [ScriptedBackend()]
        ) {
            self.settingsStore = InMemorySettingsStore(settings)
            self.store = store
            self.connectors = connectors
            self.system = RecordingSystemIntegration()
            self.coordinator = AppCoordinator(
                autoStart: false,
                settingsStore: settingsStore,
                detector: StaticEnvironment(),
                taskStore: store,
                connectorFactory: connectors,
                backendFactory: QueueBackendFactory(backends),
                systemIntegration: system,
                clock: FixedClock()
            )
        }
    }

    private func item(_ h: Harness, _ id: String) -> CollaborationItem? {
        h.coordinator.items.first { $0.id == id }
    }

    // MARK: lifecycle

    @Test("With autoStart off nothing runs on its own: no polling, no persisted items loaded, notifications configured once")
    func noAutoStart() async {
        let h = Harness(store: MemoryTaskStore(items: [AppFixtures.prItem()]))
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(h.coordinator.items.isEmpty)
        #expect(h.connectors.source.pollCount == 0)
        #expect(h.system.configureCount == 1)
    }

    @Test("Persisted items are restored, and items interrupted mid-run come back as pending")
    func restoresPersistedItems() async {
        let interrupted = AppFixtures.prItem(number: 1, status: .running)
        let draft = AppFixtures.prItem(number: 2, status: .draftReady)
        let h = Harness(store: MemoryTaskStore(items: [interrupted, draft]))

        await h.coordinator.loadPersistedItems()

        #expect(item(h, interrupted.id)?.status == .pendingConfirmation)
        #expect(item(h, draft.id)?.status == .draftReady)
    }

    // MARK: sync

    @Test("Sync puts a new review request at the top of the inbox, persists it and posts one notification")
    func syncIngestsNewRequest() async throws {
        let candidate = AppFixtures.candidate()
        let h = Harness(connectors: FakeConnectorFactory(source: ScriptedSource(.success(PollBatch(candidates: [candidate])))))
        h.coordinator.items = [AppFixtures.prItem(number: 1, status: .draftReady)]

        await h.coordinator.syncNow()

        #expect(h.coordinator.items.first?.id == candidate.item.id)
        #expect(h.coordinator.items.count == 2)
        #expect(h.system.incoming == [candidate.item.id])
        #expect(h.coordinator.lastSyncError == nil)
        #expect(h.coordinator.lastSyncAt == FixedClock().now)
        #expect(await h.store.items[candidate.item.id] != nil)
        #expect(await h.store.seen[candidate.dedupeKey] != nil)
    }

    @Test("No notification when notifications are turned off; no polling when the GitHub connector is disabled")
    func syncRespectsSettings() async {
        var quiet = AppSettings()
        quiet.notificationsEnabled = false
        let candidate = AppFixtures.candidate()
        let h1 = Harness(settings: quiet, connectors: FakeConnectorFactory(source: ScriptedSource(.success(PollBatch(candidates: [candidate])))))
        await h1.coordinator.syncNow()
        #expect(h1.coordinator.items.map(\.id) == [candidate.item.id])
        #expect(h1.system.incoming.isEmpty)

        var off = AppSettings()
        off.connectors = off.connectors.map { c in var c = c; if c.platform == .github { c.isEnabled = false }; return c }
        let h2 = Harness(settings: off)
        await h2.coordinator.syncNow()
        #expect(h2.connectors.source.pollCount == 0)
    }

    @Test("A connector error (e.g. expired token) is shown as the sync error and leaves the inbox untouched")
    func syncConnectorError() async {
        let h = Harness(connectors: FakeConnectorFactory(source: ScriptedSource(.failure(GitHubConnectorError.unauthorized))))
        let existing = AppFixtures.prItem(number: 1)
        h.coordinator.items = [existing]

        await h.coordinator.syncNow()

        #expect(h.coordinator.lastSyncError == GitHubConnectorError.unauthorized.localizedDescription)
        #expect(h.coordinator.items.map(\.id) == [existing.id])
    }

    @Test("Storage failures during sync are surfaced to the user instead of being swallowed")
    func syncStorageFailureIsVisible() async {
        let store = MemoryTaskStore()
        await store.fail(.markSeen)
        let h = Harness(store: store, connectors: FakeConnectorFactory(source: ScriptedSource(.success(PollBatch(candidates: [AppFixtures.candidate()])))))

        await h.coordinator.syncNow()

        #expect(h.coordinator.lastSyncError?.contains("markSeen") == true)
        #expect(h.coordinator.lastSystemNotice?.contains("markSeen") == true)
    }

    @Test("If the database cannot be opened the user is told, and sync refuses to run without storage")
    func databaseUnavailable() async {
        struct OpenFailure: Error, LocalizedError { var errorDescription: String? { "permission denied" } }
        let system = RecordingSystemIntegration()
        let connectors = FakeConnectorFactory()
        let coordinator = AppCoordinator(
            autoStart: false,
            settingsStore: InMemorySettingsStore(),
            detector: StaticEnvironment(),
            makeDefaultTaskStore: { throw OpenFailure() },
            connectorFactory: connectors,
            systemIntegration: system,
            clock: FixedClock()
        )

        #expect(coordinator.lastSystemNotice?.contains("permission denied") == true)
        await coordinator.syncNow()
        #expect(coordinator.lastSyncError != nil)
        #expect(connectors.source.pollCount == 0)
    }

    // MARK: PR state reconciliation

    @Test("A merged PR in the inbox is archived and the change is persisted")
    func reconcileArchivesMergedPR() async {
        let pr = AppFixtures.prItem(number: 7, status: .draftReady)
        let connectors = FakeConnectorFactory()
        connectors.status.result = PRStatusBatchResult(
            viewerLogin: "me",
            snapshots: [PRStateReconciler.key(repository: "acme/backend", number: 7): GitHubConnector.PRRemoteStatusSnapshot(
                repository: "acme/backend", number: 7, state: "MERGED", merged: true, headRefOID: "abc1234", reviews: []
            )]
        )
        let h = Harness(store: MemoryTaskStore(items: [pr]), connectors: connectors)
        h.coordinator.items = [pr]

        await h.coordinator.reconcileInboxGitHubPRStates(force: true)

        #expect(item(h, pr.id)?.status == .completed)
        #expect(item(h, pr.id)?.completionReason == .prMerged)
        #expect(await eventually { await h.store.items[pr.id]?.status == .completed })
    }

    // MARK: import

    @Test("Importing a PR link adds it to the top of the inbox and opens its confirmation card")
    func importPullRequest() async throws {
        let fetched = AppFixtures.prItem(number: 42)
        let h = Harness(connectors: FakeConnectorFactory(fetcher: ScriptedFetcher(item: fetched)))
        h.coordinator.items = [AppFixtures.prItem(number: 1)]

        let result = await h.coordinator.importPullRequest(reference: "acme/backend#42")

        #expect((try? result.get())?.id == fetched.id)
        #expect(h.coordinator.items.first?.id == fetched.id)
        #expect(h.coordinator.selectedTab == .inbox)
        #expect(h.coordinator.requestedDetailItemID == fetched.id)
        #expect(await eventually { await h.store.items[fetched.id] != nil })
    }

    @Test("A failed import returns the error and leaves the inbox unchanged")
    func importFailure() async {
        let h = Harness(connectors: FakeConnectorFactory(fetcher: ScriptedFetcher(item: nil)))
        let result = await h.coordinator.importPullRequest(reference: "acme/backend#404")

        guard case .failure = result else { Issue.record("expected failure"); return }
        #expect(h.coordinator.items.isEmpty)
    }

    // MARK: execution

    private func lodyPlan(model: String = "opus", agent: String = "Claude Code") -> ExecutionPlan {
        ExecutionPlan(engine: .lody, model: model, lodyAgentConfig: agent, launchMode: .nativeBackgroundSession)
    }

    @Test("Confirm & run: the review is dispatched to a tracked Lody session, recorded in usage, and the agent/model choice is remembered")
    func confirmAndRunSucceeds() async throws {
        let pr = AppFixtures.prItem()
        let backend = ScriptedBackend()
        let h = Harness(backends: [backend])
        h.coordinator.items = [pr]

        let task = h.coordinator.confirmAndRun(itemID: pr.id, plan: lodyPlan())
        await task?.value

        let done = try #require(item(h, pr.id))
        #expect(done.status == .draftReady)
        #expect(done.remoteSessionStatus == .running)
        #expect(done.sessionID == "lody-sess-1")
        #expect(backend.executeCount == 1)
        #expect(backend.requests.first?.plan.engine == .lody)
        #expect(h.coordinator.usageRuns.count == 1)
        #expect(h.coordinator.usageRuns.first?.engine == .lody)
        #expect(h.coordinator.settings.defaultEngine == .lody)
        #expect(h.coordinator.settings.lodyConfig.defaultAgentConfig == "Claude Code")
        #expect(h.coordinator.settings.lodyConfig.defaultModelByAgentConfig["Claude Code"] == "opus")
        #expect(h.settingsStore.savedSettings.last?.defaultEngine == .lody)
        #expect(await eventually { await h.store.items[pr.id]?.status == .draftReady })
    }

    @Test("Confirm & run: a Lody failure marks the item failed with the error")
    func confirmAndRunFails() async throws {
        let backend = ScriptedBackend()
        backend.result = .failure(AgentRunnerError.processFailed(exitCode: 1, stderr: "Workspace quota exceeded"))
        let pr = AppFixtures.prItem()
        let h = Harness(backends: [backend])
        h.coordinator.items = [pr]

        await h.coordinator.confirmAndRun(itemID: pr.id, plan: lodyPlan())?.value

        #expect(item(h, pr.id)?.status == .failed)
        #expect(item(h, pr.id)?.errorMessage?.contains("Workspace quota exceeded") == true)
        #expect(item(h, pr.id)?.sessionID == nil)
        #expect(h.coordinator.selectedTab == .inbox)
    }

    @Test("Cancelling a running review puts it back to pending; the late result never overrides that")
    func cancelRunningReview() async throws {
        let blocking = ScriptedBackend()
        blocking.blockUntilCancelled = true
        let pr = AppFixtures.prItem()
        let h = Harness(backends: [blocking])
        h.coordinator.items = [pr]

        let task = h.coordinator.confirmAndRun(itemID: pr.id, plan: lodyPlan())
        #expect(await eventually { blocking.executeCount == 1 })
        h.coordinator.cancelRunningItem(id: pr.id)
        #expect(item(h, pr.id)?.status == .pendingConfirmation)

        await task?.value
        #expect(item(h, pr.id)?.status == .pendingConfirmation)
        #expect(item(h, pr.id)?.sessionID == nil)
        #expect(h.system.completions.isEmpty)
    }

    @Test("Regression: cancel and immediately re-run — the stale run cannot reset or hijack the new run")
    func cancelThenRerun() async throws {
        let blocking = ScriptedBackend()
        blocking.blockUntilCancelled = true
        blocking.lingerAfterCancelSeconds = 0.3 // 旧运行的收尾必然发生在新运行完成之后
        let normal = ScriptedBackend()
        let pr = AppFixtures.prItem()
        let h = Harness(backends: [blocking, normal])
        h.coordinator.items = [pr]

        let first = h.coordinator.confirmAndRun(itemID: pr.id, plan: lodyPlan())
        #expect(await eventually { blocking.executeCount == 1 })
        h.coordinator.cancelRunningItem(id: pr.id)
        let second = h.coordinator.confirmAndRun(itemID: pr.id, plan: lodyPlan())

        await second?.value
        #expect(item(h, pr.id)?.status == .draftReady)
        await first?.value

        #expect(item(h, pr.id)?.status == .draftReady, "the stale run's cleanup must not reset the finished new run")
        #expect(item(h, pr.id)?.sessionID == "lody-sess-1")
        #expect(normal.executeCount == 1)
    }

    @Test("Re-review defaults to continuing the previous Lody session")
    func defaultPlanForReReview() {
        var pr = AppFixtures.prItem(sha: "def5678")
        pr.previousReview = PreviousReviewContext(
            previousItemID: "r1", reviewedHeadSHA: "abc1234", reviewedAt: Date(), engine: .lody, sessionID: "lody-1"
        )
        pr.reviewRound = 2
        let h = Harness()

        let plan = h.coordinator.defaultPlan(for: pr)

        #expect(plan.engine == .lody)
        #expect(plan.continuityMode == .continueSessionIncremental)
        #expect(plan.previousReview?.sessionID == "lody-1")
    }

    // MARK: inbox management

    @Test("Deleting an item removes it from inbox and storage but keeps its dedupe key (it will not reappear)")
    func deleteKeepsDedupeKey() async {
        let candidate = AppFixtures.candidate()
        let h = Harness(connectors: FakeConnectorFactory(source: ScriptedSource(.success(PollBatch(candidates: [candidate])))))
        await h.coordinator.syncNow()
        #expect(h.coordinator.items.count == 1)

        h.coordinator.deleteItem(id: candidate.item.id)

        #expect(h.coordinator.items.isEmpty)
        #expect(await eventually { await h.store.items[candidate.item.id] == nil })
        #expect(await h.store.seen[candidate.dedupeKey] != nil)

        await h.coordinator.syncNow()
        #expect(h.coordinator.items.isEmpty, "a deleted request must not come back on the next sync")
    }

    @Test("Marking an item done archives it with a manual reason and persists it; storage failures are reported")
    func markCompleted() async {
        let pr = AppFixtures.prItem(status: .draftReady)
        let store = MemoryTaskStore(items: [pr])
        let h = Harness(store: store)
        h.coordinator.items = [pr]

        h.coordinator.markItemCompleted(id: pr.id)

        #expect(item(h, pr.id)?.status == .completed)
        #expect(item(h, pr.id)?.completionReason == .manual)
        #expect(h.coordinator.selectedTab == .inbox || h.coordinator.selectedTab == .completed)
        #expect(await eventually { await store.items[pr.id]?.status == .completed })

        await store.fail(.deleteItem)
        h.coordinator.deleteItem(id: pr.id)
        #expect(await eventually { h.coordinator.lastSystemNotice?.contains("deleteItem") == true })
    }

    @Test("Changing a setting persists it immediately")
    func settingsArePersisted() {
        let h = Harness()
        h.coordinator.settings.notificationsEnabled = false
        #expect(h.settingsStore.savedSettings.last?.notificationsEnabled == false)
    }
}
