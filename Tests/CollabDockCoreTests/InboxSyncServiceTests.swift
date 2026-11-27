import Foundation
import Testing
@testable import CollabDockCore

/// SPEC：从 AppCoordinator.syncNow / reconcileInboxGitHubPRStates / importPullRequest 下沉到 Core 的收件箱同步服务。
@Suite("InboxSyncService — polling, dedupe, rules, backoff, PR state sync, import")
struct InboxSyncServiceTests {
    private func service(
        source: FakeSource,
        store: InMemoryTaskStore = InMemoryTaskStore(),
        status: FakePRStatusQuery? = nil,
        fetcher: FakePRFetcher? = nil,
        clock: TestClock = TestClock()
    ) -> InboxSyncService {
        InboxSyncService(source: source, prStatusQuery: status, prFetcher: fetcher, store: store, clock: clock)
    }

    // MARK: sync — intake

    @Test("Accepted candidates become new items, are marked seen + persisted, and each raises one notification")
    func acceptedCandidatesAreIngested() async throws {
        let a = Fixtures.candidate(repository: "acme/api", number: 1)
        let b = Fixtures.candidate(repository: "acme/web", number: 2)
        let source = FakeSource([.success(PollBatch(
            candidates: [a, b],
            nextCursor: SyncCursor(value: "Thu, 26 Nov 2026 10:15:00 GMT"),
            suggestedPollIntervalSeconds: 90,
            wasNotModified: false,
            rateLimit: RateLimitSnapshot(limit: 5000, remaining: 4990)
        ))])
        let store = InMemoryTaskStore()

        let result = try await service(source: source, store: store).sync(InboxSyncRequest(currentHandle: "me"))

        #expect(Set(result.newItems.map(\.id)) == [a.item.id, b.item.id])
        #expect(result.notifications.count == 2)
        #expect(Set(result.notifications.map { notification -> String in
            guard case .incomingTask(let item) = notification else { return "" }
            return item.id
        }) == [a.item.id, b.item.id])
        #expect(try await store.hasSeen(dedupeKey: a.dedupeKey))
        #expect(try await store.hasSeen(dedupeKey: b.dedupeKey))
        #expect(await store.item(a.item.id) != nil)
        #expect(try await store.loadCursor(for: .github)?.value == "Thu, 26 Nov 2026 10:15:00 GMT")
        #expect(result.state.effectivePollIntervalSeconds == 90)
        #expect(result.rateLimit?.remaining == 4990)
        #expect(result.backoff == .none)
    }

    @Test("The stored cursor is sent with the next poll, and poll interval never drops below 60s")
    func cursorAndIntervalFloor() async throws {
        let store = InMemoryTaskStore()
        await store.setCursor(SyncCursor(value: "Wed, 25 Nov 2026 08:00:00 GMT"), for: .github)
        let source = FakeSource([.success(PollBatch(candidates: [], suggestedPollIntervalSeconds: 10, wasNotModified: true))])

        let result = try await service(source: source, store: store).sync(InboxSyncRequest())

        #expect(source.pollRequests.first?.cursor?.value == "Wed, 25 Nov 2026 08:00:00 GMT")
        #expect(result.wasNotModified)
        #expect(result.state.effectivePollIntervalSeconds == 60)
    }

    @Test("Already-seen events are skipped entirely")
    func seenEventsAreSkipped() async throws {
        let a = Fixtures.candidate()
        let store = InMemoryTaskStore(seen: [a.dedupeKey: a.item.id])
        let source = FakeSource([.success(PollBatch(candidates: [a]))])

        let result = try await service(source: source, store: store).sync(InboxSyncRequest(currentHandle: "me"))

        #expect(result.newItems.isEmpty)
        #expect(result.notifications.isEmpty)
        #expect(await store.upsertedItemIDs.isEmpty)
    }

    @Test("Events rejected by the rules are not ingested and NOT marked seen (re-enabling a rule brings them back)")
    func rejectedEventsAreNotMarkedSeen() async throws {
        let a = Fixtures.candidate(triggerKind: .reviewRequested)
        let store = InMemoryTaskStore()
        let source = FakeSource([.success(PollBatch(candidates: [a]))])
        var rules = TriggerRules()
        rules.enableReviewRequested = false

        let result = try await service(source: source, store: store).sync(InboxSyncRequest(rules: rules, currentHandle: "me"))

        #expect(result.newItems.isEmpty)
        #expect(try await store.hasSeen(dedupeKey: a.dedupeKey) == false)
    }

    @Test("A candidate whose item is already in the inbox is neither duplicated, re-notified, nor allowed to overwrite the stored item")
    func existingInboxItemIsNotDuplicated() async throws {
        let a = Fixtures.candidate()
        var existing = a.item
        existing.status = .draftReady
        let store = InMemoryTaskStore(items: [existing])
        let source = FakeSource([.success(PollBatch(candidates: [a]))])

        let result = try await service(source: source, store: store).sync(
            InboxSyncRequest(existingItems: [existing], currentHandle: "me")
        )

        #expect(result.newItems.isEmpty)
        #expect(result.notifications.isEmpty)
        #expect(await store.item(existing.id)?.status == .draftReady)
    }

    @Test("Trigger hints in the @mention comment are pre-filled on the new item")
    func triggerHintsArePrefilled() async throws {
        let a = Fixtures.candidate(triggerKind: .mention, actor: "bob", body: "@me please review --model opus")
        let source = FakeSource([.success(PollBatch(candidates: [a]))])

        let result = try await service(source: source).sync(InboxSyncRequest(currentHandle: "me"))

        let item = try #require(result.newItems.first)
        #expect(item.suggestedModel == "opus")
    }

    @Test("A new round for an already-reviewed PR carries the previous review context (round 2)")
    func previousReviewIsAttached() async throws {
        var reviewed = Fixtures.prItem(repository: "acme/api", number: 1, headSHA: "1111111111111111111111111111111111111111", status: .completed)
        reviewed.sessionHandle = AgentSessionHandle(engine: .claudeCode, sessionID: "sess-1", workspacePath: "/tmp/wt", launchMode: .managedStructuredRun)
        let next = Fixtures.candidate(repository: "acme/api", number: 1, headSHA: "2222222222222222222222222222222222222222")
        let source = FakeSource([.success(PollBatch(candidates: [next]))])

        let result = try await service(source: source).sync(
            InboxSyncRequest(existingItems: [reviewed], currentHandle: "me")
        )

        let item = try #require(result.newItems.first)
        #expect(item.reviewRound == 2)
        #expect(item.previousReview?.reviewedHeadSHA == "1111111111111111111111111111111111111111")
        #expect(item.previousReview?.sessionID == "sess-1")
        #expect(item.previousReview?.engine == .claudeCode)
    }

    // MARK: sync — throttling & backoff

    @Test("Slow review-request reconciliation runs on first sync, on manual refresh, and at most every 15 minutes otherwise")
    func slowChannelReconcileIsThrottled() async throws {
        let clock = TestClock()
        let source = FakeSource([.success(PollBatch(candidates: [], wasNotModified: true))])
        let svc = service(source: source, clock: clock)

        let first = try await svc.sync(InboxSyncRequest())
        #expect(source.pollRequests.last?.reconcileNow == true)
        #expect(first.state.lastReconcileAt == clock.now)

        clock.advance(by: 5 * 60)
        let second = try await svc.sync(InboxSyncRequest(previousState: first.state))
        #expect(source.pollRequests.last?.reconcileNow == false)
        #expect(second.state.lastReconcileAt == first.state.lastReconcileAt)

        let manual = try await svc.sync(InboxSyncRequest(manual: true, previousState: second.state))
        #expect(source.pollRequests.last?.reconcileNow == true)

        clock.advance(by: 16 * 60)
        _ = try await svc.sync(InboxSyncRequest(previousState: manual.state))
        #expect(source.pollRequests.last?.reconcileNow == true)
    }

    @Test("PR fingerprints returned by a poll are fed back into the next poll")
    func fingerprintsRoundTrip() async throws {
        let source = FakeSource([
            .success(PollBatch(candidates: [], updatedPRFingerprints: ["acme/api#1": "2026-11-26T10:15:00Z"])),
            .success(PollBatch(candidates: []))
        ])
        let svc = service(source: source)

        let first = try await svc.sync(InboxSyncRequest())
        #expect(first.state.knownPRFingerprints == ["acme/api#1": "2026-11-26T10:15:00Z"])

        _ = try await svc.sync(InboxSyncRequest(previousState: first.state))
        #expect(source.pollRequests.last?.knownFingerprints == ["acme/api#1": "2026-11-26T10:15:00Z"])
    }

    @Test("A rate-limit error starts a backoff window instead of failing the sync")
    func rateLimitStartsBackoff() async throws {
        let clock = TestClock()
        let source = FakeSource([.failure(GitHubConnectorError.rateLimited(retryAfterSeconds: 120))])

        let result = try await service(source: source, clock: clock).sync(InboxSyncRequest())

        #expect(result.backoff.isRateLimited)
        #expect(result.backoff.rateLimitedUntil == clock.now.addingTimeInterval(120))
        #expect(result.state.rateLimitedUntil == clock.now.addingTimeInterval(120))
        #expect(result.newItems.isEmpty)
    }

    @Test("Inside the backoff window automatic syncs do not hit the network; a manual refresh does")
    func backoffSkipsAutomaticSyncOnly() async throws {
        let clock = TestClock()
        let source = FakeSource([.success(PollBatch(candidates: []))])
        let svc = service(source: source, clock: clock)
        let state = InboxSyncState(rateLimitedUntil: clock.now.addingTimeInterval(60))

        let skipped = try await svc.sync(InboxSyncRequest(previousState: state))
        #expect(skipped.backoff.wasSkippedDueToBackoff)
        #expect(source.pollCount == 0)

        _ = try await svc.sync(InboxSyncRequest(manual: true, previousState: state))
        #expect(source.pollCount == 1)

        clock.advance(by: 61)
        let afterWindow = try await svc.sync(InboxSyncRequest(previousState: state))
        #expect(!afterWindow.backoff.wasSkippedDueToBackoff)
        #expect(source.pollCount == 2)
    }

    @Test("Non-rate-limit connector errors (e.g. expired token) are thrown to the caller")
    func connectorErrorsPropagate() async throws {
        let source = FakeSource([.failure(GitHubConnectorError.unauthorized)])
        await #expect(throws: GitHubConnectorError.unauthorized) {
            _ = try await service(source: source).sync(InboxSyncRequest())
        }
    }

    // MARK: sync — persistence failures are reported, never swallowed

    @Test(
        "Any store failure during sync surfaces as PersistenceError with the failing operation",
        arguments: [PersistenceOperation.loadCursor, .hasSeen, .markSeen, .upsertItem, .saveCursor]
    )
    func storeFailuresAreReported(operation: PersistenceOperation) async throws {
        let store = InMemoryTaskStore()
        await store.fail(operation)
        let source = FakeSource([.success(PollBatch(
            candidates: [Fixtures.candidate()],
            nextCursor: SyncCursor(value: "Thu, 26 Nov 2026 10:15:00 GMT")
        ))])

        do {
            _ = try await service(source: source, store: store).sync(InboxSyncRequest(currentHandle: "me"))
            Issue.record("expected PersistenceError(\(operation))")
        } catch let error as PersistenceError {
            #expect(error.operation == operation)
        }
    }

    // MARK: sync — PR state reconciliation

    @Test("Sync also reconciles PR states when auto-archive is on, and skips the query entirely when it is off")
    func syncReconcilesPRStatesWhenEnabled() async throws {
        let open = Fixtures.prItem(repository: "acme/api", number: 1)
        let status = FakePRStatusQuery(PRStatusBatchResult(
            viewerLogin: "me",
            snapshots: Dictionary(uniqueKeysWithValues: [Fixtures.snapshot(repository: "acme/api", number: 1, state: "MERGED", merged: true)])
        ))
        let source = FakeSource([.success(PollBatch(candidates: []))])
        let svc = service(source: source, status: status)

        let on = try await svc.sync(InboxSyncRequest(existingItems: [open], currentHandle: "me"))
        #expect(on.prStateUpdates.map(\.itemID) == [open.id])
        #expect(on.prStateUpdates.first?.completionReason == .prMerged)

        let callsBefore = status.queriedTargets.count
        let off = try await svc.sync(InboxSyncRequest(
            manual: true,
            existingItems: [open],
            currentHandle: "me",
            autoCompleteApprovedOrClosedPRs: false
        ))
        #expect(off.prStateUpdates.isEmpty)
        #expect(status.queriedTargets.count == callsBefore)
    }

    @Test("reconcilePRStates: no eligible items → zero API calls")
    func reconcileWithEmptyInboxIsFree() async throws {
        let status = FakePRStatusQuery()
        let svc = service(source: FakeSource([]), status: status)

        let result = try await svc.reconcilePRStates(items: [Fixtures.prItem(status: .running)], viewerLogin: "me", force: true)

        #expect(status.queriedTargets.isEmpty)
        #expect(result.updates.isEmpty)
    }

    @Test("reconcilePRStates: throttled to once per 25s unless forced")
    func reconcileIsThrottled() async throws {
        let clock = TestClock()
        let status = FakePRStatusQuery()
        let svc = service(source: FakeSource([]), status: status, clock: clock)
        let items = [Fixtures.prItem()]

        let throttled = try await svc.reconcilePRStates(items: items, viewerLogin: "me", lastReconcileAt: clock.now.addingTimeInterval(-10))
        #expect(status.queriedTargets.isEmpty)
        #expect(throttled.reconciledAt == nil)

        let forced = try await svc.reconcilePRStates(items: items, viewerLogin: "me", force: true, lastReconcileAt: clock.now.addingTimeInterval(-10))
        #expect(status.queriedTargets.count == 1)
        #expect(forced.reconciledAt == clock.now)

        _ = try await svc.reconcilePRStates(items: items, viewerLogin: "me", lastReconcileAt: clock.now.addingTimeInterval(-26))
        #expect(status.queriedTargets.count == 2)
    }

    @Test("reconcilePRStates: archived items are returned updated and persisted; store failure is reported")
    func reconcilePersistsAndReportsFailures() async throws {
        let item = Fixtures.prItem(repository: "acme/api", number: 1)
        let status = FakePRStatusQuery(PRStatusBatchResult(
            viewerLogin: "me",
            snapshots: Dictionary(uniqueKeysWithValues: [Fixtures.snapshot(repository: "acme/api", number: 1, state: "CLOSED")])
        ))
        let store = InMemoryTaskStore(items: [item])
        let svc = service(source: FakeSource([]), store: store, status: status)

        let result = try await svc.reconcilePRStates(items: [item], viewerLogin: "me", force: true)
        #expect(result.updatedItems.map(\.status) == [.completed])
        #expect(result.updatedItems.first?.completionReason == .prClosed)
        #expect(await store.item(item.id)?.status == .completed)

        await store.fail(.upsertItem)
        do {
            _ = try await svc.reconcilePRStates(items: [item], viewerLogin: "me", force: true)
            Issue.record("expected PersistenceError(.upsertItem)")
        } catch let error as PersistenceError {
            #expect(error.operation == .upsertItem)
        }
    }

    // MARK: import

    @Test("Importing a PR link persists it and attaches the previous review of the same PR")
    func importAttachesPreviousReview() async throws {
        var reviewed = Fixtures.prItem(repository: "acme/api", number: 3, headSHA: "1111111111111111111111111111111111111111", status: .draftReady)
        reviewed.sessionID = "sess-old"
        let fetched = Fixtures.prItem(repository: "acme/api", number: 3, headSHA: "2222222222222222222222222222222222222222", status: .pendingConfirmation)
        let store = InMemoryTaskStore()
        let svc = service(source: FakeSource([]), store: store, fetcher: FakePRFetcher(item: fetched))

        let imported = try await svc.importPullRequest(reference: "acme/api#3", existingItems: [reviewed])

        #expect(imported.status == .pendingConfirmation)
        #expect(imported.reviewRound == 2)
        #expect(imported.previousReview?.sessionID == "sess-old")
        #expect(await store.item(imported.id) != nil)
    }

    @Test("Re-importing a PR whose same-SHA review is already finished creates a new item instead of overwriting history")
    func reimportDoesNotOverwriteFinishedReview() async throws {
        let sha = "3333333333333333333333333333333333333333"
        var finished = Fixtures.prItem(repository: "acme/api", number: 4, headSHA: sha, status: .completed)
        finished.executionOutput = Fixtures.codeReview("round 1 result")
        let fetched = Fixtures.prItem(repository: "acme/api", number: 4, headSHA: sha, status: .pendingConfirmation)
        let store = InMemoryTaskStore(items: [finished])
        let svc = service(source: FakeSource([]), store: store, fetcher: FakePRFetcher(item: fetched))

        let imported = try await svc.importPullRequest(reference: "https://github.com/acme/api/pull/4", existingItems: [finished])

        #expect(imported.id != finished.id)
        #expect(imported.status == .pendingConfirmation)
        #expect(await store.item(finished.id)?.status == .completed)
        #expect(await store.item(finished.id)?.executionOutput == Fixtures.codeReview("round 1 result"))
    }

    // MARK: findPreviousReview

    @Test("findPreviousReview picks the most recent finished review of the same PR and ignores everything else")
    func findPreviousReviewSelection() {
        let target = Fixtures.prItem(repository: "acme/api", number: 1, headSHA: "cccccccccccccccccccccccccccccccccccccccc", status: .pendingConfirmation)
        var newer = Fixtures.prItem(repository: "ACME/api", number: 1, headSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", status: .draftReady)
        newer.executionOutput = Fixtures.codeReview("newer summary")
        newer.reviewRound = 2
        let older = Fixtures.prItem(repository: "acme/api", number: 1, headSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", status: .completed, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let pending = Fixtures.prItem(repository: "acme/api", number: 1, headSHA: "dddddddddddddddddddddddddddddddddddddddd", status: .pendingConfirmation)
        let otherPR = Fixtures.prItem(repository: "acme/api", number: 2, status: .completed)

        // existingItems 与收件箱一致：最新的在前
        let context = InboxSyncService.findPreviousReview(
            for: target,
            in: [pending, otherPR, newer, older, target],
            defaultEngine: .codex
        )

        #expect(context?.previousItemID == newer.id)
        #expect(context?.reviewedHeadSHA == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        #expect(context?.reviewRound == 2)
        #expect(context?.engine == .codex) // 没有会话句柄时回退到默认引擎
        #expect(context?.summarySnippet == "newer summary")

        #expect(InboxSyncService.findPreviousReview(for: target, in: [pending, otherPR, target]) == nil)
    }
}
