import Foundation
import Testing
@testable import CollabDockApp
@testable import CollabDockCore

/// SPEC（实现前为红）：「已归档」里同一个 PR 也只显示一张卡片。
///
/// 真实复现：第 1 轮被第 2 轮取代后归档为「已进入第 2 轮」，第 2 轮随后因你在 GitHub 上 Approve 也归档，
/// 「已归档」里就出现同一个 PR 的两张卡片。被取代的轮次只是历史：数据保留（复审上下文、用量统计不受影响），
/// 但不在列表里显示，也不计入「已完成」的数量；「清空已完成」时一并删除。
@MainActor
@Suite("SPEC — the archive shows one card per PR", .serialized)
struct ArchiveOneCardPerPRSpecTests {
    private func coordinator(store: MemoryTaskStore = MemoryTaskStore()) -> AppCoordinator {
        AppCoordinator(
            autoStart: false,
            settingsStore: InMemorySettingsStore(),
            detector: StaticEnvironment(),
            taskStore: store,
            connectorFactory: FakeConnectorFactory(),
            systemIntegration: RecordingSystemIntegration(),
            clock: FixedClock()
        )
    }

    private func archived(_ number: Int, sha: String, round: Int, reason: TaskCompletionReason) -> CollaborationItem {
        var item = AppFixtures.prItem(number: number, sha: sha, status: .completed)
        item.reviewRound = round
        item.completionReason = reason
        return item
    }

    @Test("Superseded round + approved later round: the archive lists only the later round")
    func approvedLaterRoundHidesSupersededOne() {
        let round1 = archived(7, sha: "aaaaaaa", round: 1, reason: .superseded)
        let round2 = archived(7, sha: "bbbbbbb", round: 2, reason: .prApproved)
        let other = archived(8, sha: "ccccccc", round: 1, reason: .prMerged)
        let c = coordinator()
        c.items = [round2, round1, other]

        #expect(c.completedItems.map(\.id) == [round2.id, other.id])
        #expect(c.items.contains { $0.id == round1.id }, "the superseded round is hidden, not deleted")
    }

    @Test("While the later round is still in the inbox, the superseded round does not show in the archive at all")
    func supersededRoundHiddenWhileNextRoundIsActive() {
        let round1 = archived(7, sha: "aaaaaaa", round: 1, reason: .superseded)
        let round2 = AppFixtures.prItem(number: 7, sha: "bbbbbbb", status: .pendingConfirmation)
        let c = coordinator()
        c.items = [round2, round1]

        #expect(c.completedItems.isEmpty)
        #expect(c.inboxItems.map(\.id) == [round2.id])
    }

    @Test("Archived rounds archived for other reasons (manual, merged, closed, approved) are all still listed")
    func otherArchiveReasonsStayVisible() {
        let reasons: [TaskCompletionReason] = [.manual, .prApproved, .prMerged, .prClosed]
        let items = reasons.enumerated().map { archived(20 + $0.offset, sha: "d\($0.offset)d\($0.offset)d\($0.offset)d", round: 1, reason: $0.element) }
        let c = coordinator()
        c.items = items

        #expect(c.completedItems.map(\.id) == items.map(\.id))
    }

    @Test("Clearing the archive also deletes the hidden superseded rounds")
    func clearingRemovesHiddenRoundsToo() async {
        let round1 = archived(7, sha: "aaaaaaa", round: 1, reason: .superseded)
        let round2 = archived(7, sha: "bbbbbbb", round: 2, reason: .prApproved)
        let store = MemoryTaskStore(items: [round1, round2])
        let c = coordinator(store: store)
        c.items = [round2, round1]

        c.clearCompletedItems()

        #expect(c.items.isEmpty)
        #expect(await eventually { await store.items.isEmpty })
    }
}
