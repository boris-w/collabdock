import Foundation
import Testing
@testable import CollabDockApp
@testable import CollabDockCore

/// SPEC（实现前为红）：用菜单栏「+」手动导入 PR 时，也要遵守「同一个 PR 只保留一张活跃卡片」。
/// #10 只在自动同步路径上归档旧一轮；手动导入同一个 PR 的新一轮时，上一轮已处理过的卡片仍留在收件箱里。
@MainActor
@Suite("SPEC — manual PR import supersedes the previous round", .serialized)
struct ImportSupersedesSpecTests {
    private func harness(fetched: CollaborationItem, store: MemoryTaskStore) -> AppCoordinator {
        AppCoordinator(
            autoStart: false,
            settingsStore: InMemorySettingsStore(),
            detector: StaticEnvironment(),
            taskStore: store,
            connectorFactory: FakeConnectorFactory(fetcher: ScriptedFetcher(item: fetched)),
            systemIntegration: RecordingSystemIntegration(),
            clock: FixedClock()
        )
    }

    @Test("SPEC: importing a newer round archives the round I already reviewed, keeping its result")
    func importArchivesPreviousRound() async throws {
        var reviewed = AppFixtures.prItem(number: 7, sha: "aaaaaaa", status: .draftReady)
        reviewed.executionOutput = .codeReview(CodeReviewResult(summary: "round 1 findings", recommendedVerdict: .requestChanges, comments: []))
        let other = AppFixtures.prItem(number: 8, sha: "ccccccc", status: .draftReady)
        let newRound = AppFixtures.prItem(number: 7, sha: "bbbbbbb")
        let store = MemoryTaskStore(items: [reviewed, other])
        let c = harness(fetched: newRound, store: store)
        c.items = [reviewed, other]

        let result = await c.importPullRequest(reference: "acme/backend#7")

        let imported = try #require(try? result.get())
        #expect(imported.previousReview?.previousItemID == reviewed.id)
        let archived = try #require(c.items.first { $0.id == reviewed.id })
        #expect(archived.status == .completed)
        #expect(archived.completionReason == .superseded)
        #expect(archived.executionOutput == reviewed.executionOutput)
        #expect(c.items.first { $0.id == other.id }?.status == .draftReady, "other PRs are untouched")
        #expect(c.items.filter { $0.status.isInboxActive && $0.externalRef == "#7" }.map(\.id) == [imported.id])
        #expect(await eventually { await store.items[reviewed.id]?.completionReason == .superseded })
    }

    @Test("Safety net: importing a PR with no earlier round does not archive anything")
    func importWithoutHistory() async throws {
        let other = AppFixtures.prItem(number: 8, sha: "ccccccc", status: .draftReady)
        let fresh = AppFixtures.prItem(number: 9, sha: "ddddddd")
        let c = harness(fetched: fresh, store: MemoryTaskStore(items: [other]))
        c.items = [other]

        _ = await c.importPullRequest(reference: "acme/backend#9")

        #expect(c.items.first { $0.id == other.id }?.status == .draftReady)
        #expect(c.items.contains { $0.id == fresh.id })
    }
}
