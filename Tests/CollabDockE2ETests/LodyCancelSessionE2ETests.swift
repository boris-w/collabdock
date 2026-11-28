import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：在 CollabDock 里点「停止」，要真正取消 Lody 里正在进行的那一轮，
/// 而不只是 CollabDock 停止跟踪（否则 Lody 里的 agent 会继续审完、照样在 PR 上发评论）。
///
/// 用 `lody session cancel <sessionId> --json [--workspace <ws>]`。和派发一样：
/// 在中性临时目录启动、剥离宿主的 GitHub token 与 `LODY_*` 会话变量。
/// 特别注意：`lody session cancel` 不带 sessionId 时会回退到环境变量 `LODY_SESSION_ID`，
/// 所以没有会话 ID 时绝不能执行这条命令。
@Suite("E2E SPEC — stopping a review cancels the running Lody turn", .serialized)
struct LodyCancelSessionE2ETests {
    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-e2e-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func handle(_ sessionID: String) -> AgentSessionHandle {
        AgentSessionHandle(
            engine: .lody,
            sessionID: sessionID,
            workspacePath: "/Users/dev/code/backend",
            launchMode: .nativeBackgroundSession
        )
    }

    @Test("Cancel runs `lody session cancel <id> --json --workspace <ws>` from a neutral cwd with host/session variables stripped")
    func cancelsTheLodyTurn() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fake = try FakeAgentCLI(in: workspace, name: "lody", stdoutLines: [#"{"ok":true,"cancelled":true}"#])
        let backend = LodyBackend(config: LodyConfig(workspace: "ws-1"))

        try await withHostEnvironment(RealWorldGuardsE2ETests.inheritedHostVariables) {
            try await backend.cancelSession(handle("lody-sess-9"), environment: fake.environmentSnapshot(engine: .lody))
        }

        #expect(Array(fake.argv.prefix(2)) == ["session", "cancel"])
        #expect(fake.argv.contains("--json"))
        #expect(fake.value(after: "--workspace") == "ws-1")
        #expect(fake.argv.filter { $0 == "lody-sess-9" }.count == 1, "the session id is passed explicitly, exactly once")

        let cwd = try #require(fake.workingDirectory)
        #expect(cwd == realPath(FileManager.default.temporaryDirectory.path))
        let leaked = fake.environmentKeys.intersection(RealWorldGuardsE2ETests.inheritedHostVariables.keys)
        #expect(leaked.isEmpty, "leaked to lody: \(leaked.sorted())")
    }

    @Test("Without a configured workspace, no --workspace flag is passed")
    func noWorkspaceFlagWhenUnset() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fake = try FakeAgentCLI(in: workspace, name: "lody", stdoutLines: [#"{"ok":true}"#])

        try await LodyBackend(config: LodyConfig()).cancelSession(handle("lody-sess-2"), environment: fake.environmentSnapshot(engine: .lody))

        #expect(Array(fake.argv.prefix(2)) == ["session", "cancel"])
        #expect(!fake.argv.contains("--workspace"))
        #expect(fake.argv.contains("lody-sess-2"))
    }

    @Test("SPEC (safety): an empty or blank session id throws and never runs lody (it would fall back to LODY_SESSION_ID)",
          arguments: ["", "   "])
    func blankSessionIDNeverRuns(sessionID: String) async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fake = try FakeAgentCLI(in: workspace, name: "lody", stdoutLines: [#"{"ok":true}"#])

        await #expect(throws: (any Error).self) {
            try await LodyBackend(config: LodyConfig(workspace: "ws-1")).cancelSession(
                handle(sessionID), environment: fake.environmentSnapshot(engine: .lody)
            )
        }
        #expect(fake.argv.isEmpty, "lody must not be started")
    }

    @Test("A failure reported as JSON on stdout is surfaced as the error")
    func failureIsSurfaced() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fake = try FakeAgentCLI(
            in: workspace,
            name: "lody",
            stdoutLines: [#"{"ok":false,"error":"Session lody-sess-3 has no active turn"}"#],
            exitCode: 1
        )

        do {
            try await LodyBackend(config: LodyConfig()).cancelSession(handle("lody-sess-3"), environment: fake.environmentSnapshot(engine: .lody))
            Issue.record("expected the cancel to throw")
        } catch {
            #expect(error.localizedDescription.contains("has no active turn"), "\(error.localizedDescription)")
        }
    }

    @Test("LodyBackend is a SessionCancelling")
    func conformance() {
        let canceller: any SessionCancelling = LodyBackend(config: LodyConfig())
        #expect(canceller is LodyBackend)
    }
}
