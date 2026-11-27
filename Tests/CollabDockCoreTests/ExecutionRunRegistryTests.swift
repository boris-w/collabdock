import Foundation
import Testing
@testable import CollabDockCore

@Suite("ExecutionRunRegistry — per-run identity for cancel / re-run")
struct ExecutionRunRegistryTests {
    @Test("Regression: a stale run's cleanup cannot remove or overwrite the newer run")
    func staleRunCannotTouchNewRun() {
        var registry = ExecutionRunRegistry()
        let first = registry.begin(itemID: "pr-1")

        // 用户中止后立刻重跑
        let cancelledFirst = registry.cancel(itemID: "pr-1")
        #expect(cancelledFirst)
        #expect(first.primary.isCancelled)
        let second = registry.begin(itemID: "pr-1")

        // 旧任务稍后才走到收尾逻辑
        #expect(!registry.isCurrent(first))
        registry.finish(first)

        #expect(registry.isCurrent(second))
        #expect(registry.isRunning(itemID: "pr-1"))
        #expect(!second.isCancelled)

        // 新任务仍然可以被中止
        let cancelledSecond = registry.cancel(itemID: "pr-1")
        #expect(cancelledSecond)
        #expect(second.primary.isCancelled)
        #expect(second.secondary.isCancelled)
        #expect(!registry.isRunning(itemID: "pr-1"))
    }

    @Test("Beginning a new run supersedes and cancels an in-flight run for the same item")
    func beginSupersedesPreviousRun() {
        var registry = ExecutionRunRegistry()
        let first = registry.begin(itemID: "pr-1")
        let second = registry.begin(itemID: "pr-1")

        #expect(first.isCancelled)
        #expect(!registry.isCurrent(first))
        #expect(registry.isCurrent(second))
    }

    @Test("Runs for different items are independent; finishing the current run clears it")
    func independentItems() {
        var registry = ExecutionRunRegistry()
        let a = registry.begin(itemID: "a")
        let b = registry.begin(itemID: "b")

        registry.cancel(itemID: "a")
        #expect(a.isCancelled)
        #expect(!b.isCancelled)
        #expect(registry.isCurrent(b))

        registry.finish(b)
        #expect(!registry.isRunning(itemID: "b"))
        let cancelledAfterFinish = registry.cancel(itemID: "b")
        #expect(!cancelledAfterFinish)
    }
}
