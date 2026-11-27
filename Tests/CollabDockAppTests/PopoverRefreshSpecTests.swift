import Foundation
import Testing
@testable import CollabDockApp
@testable import CollabDockCore

/// SPEC（实现前为红）：打开菜单栏弹窗时自动刷新收件箱。
///
/// 真实情况：用户的 GitHub 通知接口不返回任何内容（通知只走邮件），实时通道失效，新请求只能等慢速 Search 对齐；
/// 打开弹窗时又只做 PR 状态对齐、不做同步，于是「要手动点刷新才出现」。
/// 期望：打开弹窗时，若距上次 Search 对齐已超过 60 秒，就立即做一次带对齐的同步；60 秒内重复打开不重复请求。
@MainActor
@Suite("SPEC — refresh the inbox when the menu bar popover opens", .serialized)
struct PopoverRefreshSpecTests {
    private func harness(clock: MutableClock, source: ScriptedSource) -> AppCoordinator {
        AppCoordinator(
            autoStart: false,
            settingsStore: InMemorySettingsStore(),
            detector: StaticEnvironment(),
            taskStore: MemoryTaskStore(),
            connectorFactory: FakeConnectorFactory(source: source),
            systemIntegration: RecordingSystemIntegration(),
            clock: clock
        )
    }

    @Test("SPEC: opening the popover runs a reconciling sync and shows new review requests without a manual refresh")
    func openingPopoverSyncs() async throws {
        let clock = MutableClock()
        let candidate = AppFixtures.candidate(number: 42)
        let source = ScriptedSource(.success(PollBatch(candidates: [candidate])))
        let c = harness(clock: clock, source: source)

        await c.popoverDidOpen()

        #expect(source.pollCount == 1)
        #expect(source.requests.last?.reconcileNow == true, "the search channel must run — notifications may deliver nothing")
        #expect(c.items.map(\.id) == [candidate.item.id])
    }

    @Test("SPEC: re-opening within 60 seconds does not poll again; after 60 seconds it does")
    func openingIsThrottled() async throws {
        let clock = MutableClock()
        let source = ScriptedSource()
        let c = harness(clock: clock, source: source)

        await c.popoverDidOpen()
        clock.advance(by: 30)
        await c.popoverDidOpen()
        #expect(source.pollCount == 1)

        clock.advance(by: 31)
        await c.popoverDidOpen()
        #expect(source.pollCount == 2)
    }

    @Test("SPEC: a recent automatic reconcile also counts — no extra poll right after one")
    func recentReconcileCounts() async throws {
        let clock = MutableClock()
        let source = ScriptedSource()
        let c = harness(clock: clock, source: source)

        await c.syncNow(manual: true)          // 刚刚做过一次带对齐的同步
        clock.advance(by: 20)
        await c.popoverDidOpen()

        #expect(source.pollCount == 1)
    }
}
