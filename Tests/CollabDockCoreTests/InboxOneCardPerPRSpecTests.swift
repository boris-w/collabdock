import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：同一个 PR 在收件箱里只保留一张「待确认」卡片。
/// 场景：作者先 @我、隔一会儿又点 Re-request review —— 两个事件常落在不同的同步轮次里，不能出现两张卡片、两次通知。
@Suite("SPEC — one pending card per PR")
struct InboxOneCardPerPRSpecTests {
    private func card(_ id: String, kind: TriggerKind, status: CollaborationTaskStatus = .pendingConfirmation, repo: String = "acme/api", number: Int = 1) -> CollaborationItem {
        CollaborationItem(
            id: id,
            platform: .github,
            itemKind: .pullRequest,
            scope: repo,
            externalRef: "#\(number)",
            title: "PR \(number)",
            url: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
            author: "carol",
            triggeredBy: "carol",
            triggerKind: kind,
            triggerBody: kind == .mention ? "@me " : nil,
            payload: .codeChange(CodeChangePayload(
                repository: repo, number: number, baseRef: "main", headRef: "feat/x",
                headSHA: "abcdef0123456789abcdef0123456789abcdef01", additions: 1, deletions: 0, changedFiles: 1
            )),
            status: status
        )
    }

    private func candidate(_ item: CollaborationItem) -> PolledCollaborationCandidate {
        PolledCollaborationCandidate(
            dedupeKey: item.id,
            event: IncomingCollaborationEvent(
                platform: .github, scope: item.scope, externalRef: item.externalRef,
                triggerKind: item.triggerKind, actor: "carol", body: item.triggerKind == .mention ? "@me please review" : nil
            ),
            item: item
        )
    }

    @Test("A re-request arriving while a pending card for the same PR exists does not add a second card or notification")
    func laterEventMergesIntoPendingCard() async throws {
        let pendingMention = card("github:acme/api#1:mention:c900", kind: .mention)
        let reRequest = candidate(card("github:acme/api#1:reviewRequested:abcdef0@rr:2026-11-27T05:37:16Z", kind: .reviewRequested))
        let store = InMemoryTaskStore(items: [pendingMention])
        let service = InboxSyncService(source: FakeSource([.success(PollBatch(candidates: [reRequest]))]), store: store)

        let result = try await service.sync(InboxSyncRequest(existingItems: [pendingMention], currentHandle: "me"))

        #expect(result.newItems.isEmpty)
        #expect(result.notifications.isEmpty)
        #expect(try await store.hasSeen(dedupeKey: reRequest.dedupeKey), "marked seen so it never shows up later as a stale duplicate")
    }

    @Test("Two events for the same PR in one sync produce one card, preferring the review request")
    func sameBatchProducesOneCard() async throws {
        let mention = candidate(card("github:acme/api#1:mention:c900", kind: .mention))
        let reRequest = candidate(card("github:acme/api#1:reviewRequested:abcdef0@rr:2026-11-27T05:37:16Z", kind: .reviewRequested))
        let store = InMemoryTaskStore()
        let service = InboxSyncService(source: FakeSource([.success(PollBatch(candidates: [mention, reRequest]))]), store: store)

        let result = try await service.sync(InboxSyncRequest(currentHandle: "me"))

        #expect(result.newItems.count == 1)
        #expect(result.newItems.first?.triggerKind == .reviewRequested)
        #expect(result.notifications.count == 1)
        #expect(try await store.hasSeen(dedupeKey: mention.dedupeKey))
        #expect(try await store.hasSeen(dedupeKey: reRequest.dedupeKey))
    }

    @Test("Cards I already acted on (draft ready / done) do not block a new round for the same PR")
    func actedOnCardsDoNotBlockNewRound() async throws {
        let reviewed = card("github:acme/api#1:reviewRequested:abcdef0", kind: .reviewRequested, status: .draftReady)
        let reRequest = candidate(card("github:acme/api#1:reviewRequested:abcdef0@rr:2026-11-27T05:37:16Z", kind: .reviewRequested))
        let service = InboxSyncService(source: FakeSource([.success(PollBatch(candidates: [reRequest]))]), store: InMemoryTaskStore(items: [reviewed]))

        let result = try await service.sync(InboxSyncRequest(existingItems: [reviewed], currentHandle: "me"))

        #expect(result.newItems.map(\.id) == [reRequest.item.id])
    }

    @Test("SPEC: a new round archives the previous round's card I already acted on, keeping it as history")
    func newRoundSupersedesPreviousRound() async throws {
        var reviewed = card("github:acme/api#1:reviewRequested:abcdef0", kind: .reviewRequested, status: .draftReady)
        reviewed.gitHubReviewVerdict = "CHANGES_REQUESTED"
        let otherPR = card("github:acme/api#2:reviewRequested:abcdef0", kind: .reviewRequested, status: .draftReady, number: 2)
        let newRound = candidate(card("github:acme/api#1:reviewRequested:dc186a6", kind: .reviewRequested))
        let store = InMemoryTaskStore(items: [reviewed, otherPR])
        let service = InboxSyncService(source: FakeSource([.success(PollBatch(candidates: [newRound]))]), store: store)

        let result = try await service.sync(InboxSyncRequest(existingItems: [reviewed, otherPR], currentHandle: "me"))

        #expect(result.newItems.map(\.id) == [newRound.item.id])
        #expect(result.newItems.first?.previousReview?.previousItemID == reviewed.id, "history stays linked from the new round")
        let superseded = try #require(result.supersededItems.first)
        #expect(result.supersededItems.map(\.id) == [reviewed.id], "only the same PR's previous round")
        #expect(superseded.status == .completed)
        #expect(superseded.completionReason == .superseded)
        #expect(superseded.executionOutput == reviewed.executionOutput, "the previous review result is kept")
        #expect(await store.item(reviewed.id)?.status == .completed)
        #expect(await store.item(otherPR.id)?.status == .draftReady)
    }

    @Test("Other PRs are unaffected")
    func otherPRsUnaffected() async throws {
        let pendingOther = card("github:acme/api#2:reviewRequested:abcdef0", kind: .reviewRequested, number: 2)
        let reRequest = candidate(card("github:acme/api#1:reviewRequested:abcdef0", kind: .reviewRequested))
        let service = InboxSyncService(source: FakeSource([.success(PollBatch(candidates: [reRequest]))]), store: InMemoryTaskStore(items: [pendingOther]))

        let result = try await service.sync(InboxSyncRequest(existingItems: [pendingOther], currentHandle: "me"))

        #expect(result.newItems.map(\.id) == [reRequest.item.id])
    }
}
