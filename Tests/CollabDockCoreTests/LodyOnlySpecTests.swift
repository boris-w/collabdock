import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：执行只走 Lody。
///
/// 直连 Claude / Codex / agy 已移除（连同托管 JSON 运行、双模型会诊、CollabDock 自己写 GitHub 草稿 / 本地报告、审查语言）。
/// 引擎枚举保留旧值只为读得出历史数据：旧的任务、用量记录、上一轮审查上下文都要能正常加载，但永远不会再被提供或执行。
@Suite("SPEC — Lody is the only execution path")
struct LodyOnlySpecTests {

    // MARK: offered engines

    @Test("Only Lody is offered as an engine, and Lody is the only backend kind")
    func onlyLodyIsSelectable() {
        #expect(AgentEngine.selectableEngines == [.lody])
        #expect(ExecutionBackendKind.allCases == [.lody])
        #expect(LodyBackend().kind == .lody)
    }

    // MARK: settings

    @Test("Fresh settings default to Lody")
    func freshSettingsDefaultToLody() {
        #expect(AppSettings().defaultEngine == .lody)
    }

    @Test("A saved default engine of claude / codex / agy loads as Lody", arguments: ["claude", "codex", "agy"])
    func legacyDefaultEngineBecomesLody(raw: String) throws {
        let json = #"{"defaultEngine": "\#(raw)", "pollIntervalSeconds": 120}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.defaultEngine == .lody)
        #expect(decoded.pollIntervalSeconds == 120)
    }

    @Test("Settings saved by the direct-CLI era (per-engine models / modes / paths, review language) still load, keeping the rest")
    func legacyDirectEngineKeysAreIgnored() throws {
        let json = """
        {
          "pollIntervalSeconds": 180,
          "defaultEngine": "codex",
          "defaultModels": ["claude", "opus", "codex", "gpt-5.3-codex", "agy", "gemini-4-neon-xhigh", "lody", "default"],
          "defaultModes": ["claude", "plan", "codex", "read-only", "agy", "plan", "lody", "auto"],
          "defaultLaunchMode": "managedStructuredRun",
          "customExecutablePaths": {"claude": "/opt/homebrew/bin/claude", "lody": "/usr/local/bin/lody"},
          "reviewLanguage": "en",
          "appLanguage": "en",
          "lodyConfig": {"workspace": "ws-1", "defaultAgentConfig": "Claude Code"}
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.defaultEngine == .lody)
        #expect(decoded.pollIntervalSeconds == 180)
        #expect(decoded.appLanguage == .en)
        #expect(decoded.lodyConfig.workspace == "ws-1")
        #expect(decoded.lodyConfig.defaultAgentConfig == "Claude Code")
        #expect(decoded.customExecutablePaths["lody"] == "/usr/local/bin/lody")
    }

    // MARK: history written by the direct-CLI era

    @Test("A persisted task from a direct-CLI review (Codex handle, managed run, CollabDock draft, Claude previous round) still loads")
    func legacyPersistedItemLoads() throws {
        var item = Fixtures.prItem()
        item.sessionHandle = AgentSessionHandle(engine: .lody, sessionID: "sess-legacy", workspacePath: "/tmp/wt", launchMode: .nativeBackgroundSession)
        item.sessionID = "sess-legacy"
        item.executionOutput = Fixtures.codeReview("round 1 findings")
        item.previousReview = PreviousReviewContext(
            previousItemID: "r0", reviewedHeadSHA: "1111111", reviewedAt: Date(timeIntervalSince1970: 1_800_000_000),
            engine: .lody, sessionID: "sess-r0", reviewRound: 1
        )
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        var handle = try #require(object["sessionHandle"] as? [String: Any])
        handle["engine"] = "codex"
        handle["launchMode"] = "managedStructuredRun"
        object["sessionHandle"] = handle
        var previous = try #require(object["previousReview"] as? [String: Any])
        previous["engine"] = "claude"
        object["previousReview"] = previous
        object["suggestedEngine"] = "agy"
        object["localReportPath"] = "/Users/dev/Library/Application Support/CollabDock/reports/x.md"
        object["deliveryURL"] = "https://github.com/acme/backend/pull/1#pullrequestreview-1"

        let decoded = try JSONDecoder().decode(CollaborationItem.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.id == item.id)
        #expect(decoded.sessionID == "sess-legacy")
        #expect(decoded.sessionHandle?.engine == .codex)
        #expect(decoded.previousReview?.engine == .claudeCode)
        guard case .codeReview(let review)? = decoded.executionOutput else {
            Issue.record("the legacy code review output must still load"); return
        }
        #expect(review.summary == "round 1 findings")
    }

    @Test("Usage history recorded by direct CLIs (including council partners) still loads with its engine label")
    func legacyUsageRunLoads() throws {
        let run = ReviewUsageRun(
            itemID: "github:acme/backend#1", platform: .github, scope: "acme/backend", externalRef: "#1", title: "PR 1",
            engine: .lody, model: "gpt-5.3-codex", effort: .high, usage: AgentUsageMetrics(inputTokens: 10, outputTokens: 5)
        )
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        object["engine"] = "codex"
        object["isCouncilSecondary"] = true

        let decoded = try JSONDecoder().decode(ReviewUsageRun.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.engine == .codex)
        #expect(decoded.model == "gpt-5.3-codex")
        #expect(decoded.usage.inputTokens == 10)
    }

    // MARK: execution always lands on Lody

    private func dispatchedResult(_ sessionID: String) -> AgentRunResult {
        AgentRunResult(
            output: nil,
            sessionHandle: AgentSessionHandle(engine: .lody, sessionID: sessionID, workspacePath: "/tmp/wt", launchMode: .nativeBackgroundSession),
            rawOutputText: "",
            wasBackgroundDispatched: true
        )
    }

    private func request(_ item: CollaborationItem, plan: ExecutionPlan) -> ReviewExecutionRequest {
        ReviewExecutionRequest(item: item, plan: plan, preset: TaskPreset.defaults[0], ticket: ExecutionRunTicket(itemID: item.id))
    }

    @Test("A plan naming a direct engine still runs on Lody, as a background session with the agent's default model",
          arguments: [AgentEngine.claudeCode, .codex, .antigravity])
    func directEnginePlanRunsOnLody(engine: AgentEngine) async throws {
        let lody = FakeBackend()
        lody.result = dispatchedResult("lody-9")
        let store = InMemoryTaskStore()
        let service = ReviewExecutionService(backend: lody, store: store)
        let item = Fixtures.prItem(status: .pendingConfirmation)

        let outcome = try await service.execute(request(item, plan: ExecutionPlan(engine: engine, model: "gpt-5.3-codex")))

        guard case .backgroundDispatched(let tracked, _, _, let usageRuns) = outcome else {
            Issue.record("expected .backgroundDispatched, got \(outcome)"); return
        }
        let exec = try #require(lody.executeRequests.first)
        #expect(exec.plan.engine == .lody)
        #expect(exec.plan.launchMode == .nativeBackgroundSession)
        #expect(exec.plan.model == "default", "a direct-CLI model id means nothing to a Lody agent")
        #expect(tracked.sessionID == "lody-9")
        #expect(usageRuns.map(\.engine) == [.lody])
        #expect(await store.item(item.id)?.status == .draftReady)
    }

    @Test("A previous round reviewed by a direct engine starts a new Lody session instead of chatting into a foreign session id")
    func foreignPreviousSessionStartsFresh() async throws {
        let lody = FakeBackend()
        lody.result = dispatchedResult("lody-new")
        let service = ReviewExecutionService(backend: lody, store: InMemoryTaskStore())
        let previous = PreviousReviewContext(
            previousItemID: "r1", reviewedHeadSHA: "1111111", reviewedAt: Date(), engine: .claudeCode, sessionID: "claude-sess-1", reviewRound: 1
        )
        var item = Fixtures.prItem(status: .pendingConfirmation)
        item.previousReview = previous
        item.reviewRound = 2
        let plan = ExecutionPlan(
            engine: .lody, model: "default", launchMode: .nativeBackgroundSession,
            continuityMode: .continueSessionIncremental, previousReview: previous
        )

        let outcome = try await service.execute(request(item, plan: plan))

        guard case .backgroundDispatched(_, _, let continued, _) = outcome else {
            Issue.record("expected .backgroundDispatched, got \(outcome)"); return
        }
        let exec = try #require(lody.executeRequests.first)
        #expect(exec.plan.continuityMode == .freshSessionIncremental)
        #expect(continued == false)
    }

    @Test("The Lody command for a foreign previous session is `session create`, never `session chat <foreign id>`")
    func foreignPreviousSessionCommand() {
        let previous = PreviousReviewContext(
            previousItemID: "r1", reviewedHeadSHA: "1111111", reviewedAt: Date(), engine: .codex, sessionID: "codex-thread-1"
        )
        let plan = ExecutionPlan(
            engine: .lody, model: "default", launchMode: .nativeBackgroundSession,
            continuityMode: .continueSessionIncremental, previousReview: previous
        )
        let spec = AgentCommandBuilder().buildBackgroundDispatchCommand(
            plan: plan, prompt: "PR updated", workspaceURL: URL(fileURLWithPath: "/tmp/wt")
        )
        #expect(Array(spec.arguments.prefix(2)) == ["session", "create"])
        #expect(!spec.arguments.contains("codex-thread-1"))
    }

    // MARK: trigger hints

    @Test("Comment hints never pick a direct engine; a Lody hint and the other hints still work")
    func directEngineHintsAreIgnored() {
        let engine = TriggerRuleEngine()
        for body in ["@dev review --engine codex", "@dev review --cli claude", "@dev review --engine agy", "@dev review --engine claude-code"] {
            #expect(engine.parseHints(from: body).engine == nil, "\(body)")
        }
        let modelHint = engine.parseHints(from: "@dev review --model gpt-5.3-codex --focus security")
        #expect(modelHint.engine == nil, "a model id must not switch the engine")
        #expect(modelHint.model == "gpt-5.3-codex")
        #expect(modelHint.focus == "security")
        #expect(engine.parseHints(from: "@dev review --engine lody").engine == .lody)
    }
}
