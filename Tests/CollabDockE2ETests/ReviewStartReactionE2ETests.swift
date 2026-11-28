import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：真实链路下，CollabDock 往 GitHub 写的唯一一样东西是开始审查时的 👀。
/// 打开开关：派发成功后恰好一次 `POST /repos/<repo>/issues/<n>/reactions`，body `{"content":"eyes"}`，带 token；
/// 关掉开关：零写入（只有 GET 与 GraphQL 查询）。
@Suite("E2E SPEC — the 👀 reaction is CollabDock's only write to GitHub", .serialized, .enabled(if: GitSandbox.isGitAvailable))
struct ReviewStartReactionE2ETests {
    private static let lodyOK = #"{"ok":true,"sessionId":"lody-sess-1","status":"running"}"#

    private func run(react: Bool) async throws -> PRScenario {
        let scenario = try await PRScenario.make()
        scenario.github.on(
            "POST", "/repos/\(PRScenario.repository)/issues/\(PRScenario.number)/reactions",
            json: #"{"id": 1, "content": "eyes"}"#, status: 201
        )
        let item = try #require(try await scenario.connector.poll(cursor: nil).candidates.first?.item)

        let neutral = scenario.sandbox.root.appendingPathComponent("neutral-cwd", isDirectory: true)
        try FileManager.default.createDirectory(at: neutral, withIntermediateDirectories: true)
        let fake = try FakeAgentCLI(in: scenario.sandbox.root, name: "lody", stdoutLines: [Self.lodyOK])
        let backend = LodyBackend(
            catalog: LodyCatalogSnapshot(),
            worktreeManager: scenario.worktreeManager,
            temporaryWorkingDirectory: neutral
        )
        let store = try SQLiteTaskStore(databasePath: scenario.sandbox.root.appendingPathComponent("db.sqlite").path)
        let service = ReviewExecutionService(backend: backend, store: store, reactor: scenario.connector)

        let outcome = try await service.execute(ReviewExecutionRequest(
            item: item,
            plan: ExecutionPlan(engine: .lody, model: "default", launchMode: .nativeBackgroundSession, useIsolatedWorktree: true),
            preset: TaskPreset.defaults[0],
            ticket: ExecutionRunTicket(itemID: item.id),
            preferredLocalPath: scenario.sandbox.userRepo.path,
            environment: fake.environmentSnapshot(engine: .lody),
            addStartReaction: react
        ))
        guard case .backgroundDispatched = outcome else {
            Issue.record("expected the review to be dispatched, got \(outcome)")
            return scenario
        }
        return scenario
    }

    private func writes(_ github: FakeGitHub) -> [FakeGitHub.RecordedRequest] {
        github.requests.filter { $0.method != "GET" && $0.path != "/graphql" }
    }

    @Test("Switch on: exactly one POST of 👀 to the PR, with the token, after the session is dispatched")
    func reactionIsTheOnlyWrite() async throws {
        let scenario = try await run(react: true)
        defer { scenario.sandbox.cleanup() }

        let w = writes(scenario.github)
        #expect(w.map { "\($0.method) \($0.path)" } == ["POST /repos/\(PRScenario.repository)/issues/\(PRScenario.number)/reactions"])
        let post = try #require(w.first)
        #expect(post.jsonBody?["content"] as? String == "eyes")
        #expect(post.headers["Authorization"]?.contains(PRScenario.token) == true)
    }

    @Test("Switch off: CollabDock writes nothing to GitHub")
    func noWritesWhenOff() async throws {
        let scenario = try await run(react: false)
        defer { scenario.sandbox.cleanup() }

        #expect(writes(scenario.github).isEmpty, "\(writes(scenario.github).map { "\($0.method) \($0.path)" })")
    }
}
