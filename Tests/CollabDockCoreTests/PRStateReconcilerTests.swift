import Foundation
import Testing
@testable import CollabDockCore

@Suite("PRStateReconciler — inbox ↔ GitHub PR state sync [ITER-017]")
struct PRStateReconcilerTests {
    @Test("Targets are deduplicated and skip running, Lody-running, demo, archived and non-PR items")
    func targetsSkipIneligibleItems() {
        let items: [CollaborationItem] = [
            Fixtures.prItem(repository: "acme/api", number: 1),
            Fixtures.prItem(repository: "ACME/api", number: 1, headSHA: "bbbbbbb"), // same PR, different round
            Fixtures.prItem(repository: "acme/api", number: 2, status: .running),
            Fixtures.prItem(repository: "acme/api", number: 3, status: .preparing),
            Fixtures.prItem(repository: "acme/api", number: 4, remoteSessionStatus: .running),
            Fixtures.prItem(repository: "acme/api", number: 5, idPrefix: "demo-gh"),
            Fixtures.prItem(repository: "acme/api", number: 6, status: .completed),
            Fixtures.prItem(repository: "acme/web", number: 7, status: .pendingConfirmation),
            Fixtures.chatItem()
        ]

        let targets = PRStateReconciler.targets(in: items)

        #expect(targets.map(\.key) == ["acme/api#1", "acme/web#7"])
    }

    @Test("Regression: inbox reordered during the network await still archives the right item")
    func updatesAreKeyedByItemIDNotIndex() {
        let merged = Fixtures.prItem(repository: "acme/api", number: 1)
        let open = Fixtures.prItem(repository: "acme/web", number: 2)
        let before = [merged, open]
        let targets = PRStateReconciler.targets(in: before)
        #expect(targets.count == 2)

        // 网络请求期间：新通知插到最前面、另一条被用户删掉后又导入 —— 旧下标全部失效
        let newcomer = Fixtures.prItem(repository: "acme/new", number: 3, status: .pendingConfirmation)
        var after = [newcomer, open, merged]

        let snapshots = Dictionary(uniqueKeysWithValues: [
            Fixtures.snapshot(repository: "acme/api", number: 1, state: "MERGED", merged: true),
            Fixtures.snapshot(repository: "acme/web", number: 2)
        ])

        let updates = PRStateReconciler.updates(for: after, snapshots: snapshots, viewerLogin: "me")
        #expect(updates == [
            PRStateReconciler.Update(itemID: merged.id, completionReason: .prMerged, latestViewerVerdict: "MERGED")
        ])

        for update in updates {
            let idx = try! #require(after.firstIndex(where: { $0.id == update.itemID }))
            PRStateReconciler.apply(update, to: &after[idx])
        }
        #expect(after[0].status == .pendingConfirmation) // newcomer untouched
        #expect(after[1].status == .draftReady)          // open PR untouched
        #expect(after[2].status == .completed)
        #expect(after[2].completionReason == .prMerged)
    }

    @Test("An item that started running while the request was in flight is not archived")
    func runningItemsAreRecheckedAfterAwait() {
        var item = Fixtures.prItem(repository: "acme/api", number: 1)
        #expect(PRStateReconciler.targets(in: [item]).count == 1)

        item.status = .running
        let snapshots = Dictionary(uniqueKeysWithValues: [
            Fixtures.snapshot(repository: "acme/api", number: 1, state: "CLOSED")
        ])

        #expect(PRStateReconciler.updates(for: [item], snapshots: snapshots, viewerLogin: "me").isEmpty)
    }

    @Test("CHANGES_REQUESTED only updates the verdict and keeps the item in the inbox; unchanged verdict is a no-op")
    func changesRequestedKeepsItemInInbox() {
        let head = "cccccccccccccccccccccccccccccccccccccccc"
        let item = Fixtures.prItem(repository: "acme/api", number: 9, headSHA: head)
        let review = GitHubConnector.PRRemoteReviewEntry(
            state: "CHANGES_REQUESTED",
            authorLogin: "Me",
            submittedAt: item.createdAt.addingTimeInterval(120),
            commitOID: head
        )
        let snapshots = Dictionary(uniqueKeysWithValues: [
            Fixtures.snapshot(repository: "acme/api", number: 9, headRefOID: head, reviews: [review])
        ])

        let updates = PRStateReconciler.updates(for: [item], snapshots: snapshots, viewerLogin: "me")
        let update = try! #require(updates.first)
        #expect(updates.count == 1)
        #expect(update.completionReason == nil)
        #expect(update.latestViewerVerdict == "CHANGES_REQUESTED")

        var applied = item
        PRStateReconciler.apply(update, to: &applied)
        #expect(applied.status == .draftReady)
        #expect(applied.status.isInboxActive)
        #expect(applied.gitHubReviewVerdict == "CHANGES_REQUESTED")

        // 再同步一次：verdict 未变化 → 不产生更新（也就不会重复写库）
        #expect(PRStateReconciler.updates(for: [applied], snapshots: snapshots, viewerLogin: "me").isEmpty)
    }

    @Test("Snapshots for PRs no longer in the inbox are ignored")
    func snapshotsWithoutMatchingItemsAreIgnored() {
        let item = Fixtures.prItem(repository: "acme/api", number: 1)
        let snapshots = Dictionary(uniqueKeysWithValues: [
            Fixtures.snapshot(repository: "acme/other", number: 1, state: "MERGED", merged: true)
        ])
        #expect(PRStateReconciler.updates(for: [item], snapshots: snapshots, viewerLogin: "me").isEmpty)
    }
}
