import Foundation
import Testing
@testable import CollabDockCore

/// 安全网：这些行为来自真实机器上踩过的坑（见 pm/05-iterations/ITER-010、ITER-013、ITER-015 及 lody 修复提交）。
/// 看起来像「奇怪的特判」，重构执行后端（直连 CLI / Lody）时必须保持。
@Suite("E2E — real-world guards that the execution-backend refactor must keep", .serialized)
struct RealWorldGuardsE2ETests {
    static let inheritedHostVariables: [String: String] = [
        "GITHUB_TOKEN": "ghp_host_secret",
        "GH_TOKEN": "ghp_host_secret",
        "GH_ENTERPRISE_TOKEN": "ghp_host_secret",
        // CollabDock 可能从 Lody 桌面端 / Electron 宿主里被拉起，这些变量会让子进程串到父会话
        "ELECTRON_RUN_AS_NODE": "1",
        "LODY_ELECTRON_BOOTSTRAP": "1",
        "LODY_SESSION_ID": "parent-session",
        "LODY_WORKSPACE_SESSION_ID": "parent-workspace-session",
        "LODY_AGENT_SESSION_ID": "parent-agent-session"
    ]

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-e2e-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item() -> CollaborationItem {
        CollaborationItem(
            id: "github:acme/backend#7:reviewRequested:abc1234",
            platform: .github,
            itemKind: .pullRequest,
            scope: "acme/backend",
            externalRef: "#7",
            title: "feat: add ttl",
            url: URL(string: "https://github.com/acme/backend/pull/7")!,
            author: "alice",
            triggeredBy: "alice",
            triggerKind: .reviewRequested,
            payload: .codeChange(
                CodeChangePayload(
                    repository: "acme/backend", number: 7, baseRef: "main", headRef: "feat/cache",
                    headSHA: "abc1234", additions: 1, deletions: 0, changedFiles: 1
                )
            )
        )
    }

    @Test("Lody: dispatches a background session from a neutral cwd and strips inherited host/session variables")
    func lodyBackgroundDispatch() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        // 目标仓库里放一个同名 package.json：若在仓库目录里启动 `npx lody` 会被它劫持
        try #"{"name":"lody","version":"0.0.0"}"#.write(
            to: workspace.appendingPathComponent("package.json"), atomically: true, encoding: .utf8
        )
        let fake = try FakeAgentCLI(
            in: workspace,
            name: "lody",
            stdoutLines: [#"{"ok":true,"sessionId":"lody-sess-1","status":"running"}"#]
        )

        let run = try await withHostEnvironment(Self.inheritedHostVariables) {
            try await AgentSessionRunner().run(
                item: item(),
                plan: ExecutionPlan(engine: .lody, model: "gemini-4-neon", launchMode: .nativeBackgroundSession),
                preset: TaskPreset.defaults[0],
                workspaceURL: workspace,
                environmentSnapshot: fake.environmentSnapshot(engine: .lody),
                lodyConfig: LodyConfig(),
                lodyWorkspaceTarget: .preparedLocalPath(workspace.path),
                cancellationToken: ProcessCancellationToken(),
                onProgress: { _ in }
            )
        }

        #expect(run.wasBackgroundDispatched)
        #expect(run.output == nil)
        #expect(run.sessionHandle?.sessionID == "lody-sess-1")
        #expect(run.sessionHandle?.engine == .lody)
        #expect(Array(fake.argv.prefix(3)) == ["session", "create", "--json"])
        #expect(fake.value(after: "--local-project") == workspace.path)

        let cwd = try #require(fake.workingDirectory)
        #expect(cwd != realPath(workspace.path), "lody must not be started inside the target repository")
        #expect(cwd == realPath(FileManager.default.temporaryDirectory.path))

        let leaked = fake.environmentKeys.intersection(Self.inheritedHostVariables.keys)
        #expect(leaked.isEmpty, "leaked to agent process: \(leaked.sorted())")
    }

    @Test("Lody: a failure reported as JSON on stdout (empty stderr) is surfaced to the user")
    func lodyStdoutJSONError() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fake = try FakeAgentCLI(
            in: workspace,
            name: "lody",
            stdoutLines: [#"{"ok":false,"error":"Workspace quota exceeded for this month"}"#],
            exitCode: 1
        )

        do {
            _ = try await AgentSessionRunner().run(
                item: item(),
                plan: ExecutionPlan(engine: .lody, model: "gemini-4-neon", launchMode: .nativeBackgroundSession),
                preset: TaskPreset.defaults[0],
                workspaceURL: workspace,
                environmentSnapshot: fake.environmentSnapshot(engine: .lody),
                lodyConfig: LodyConfig(),
                lodyWorkspaceTarget: .preparedLocalPath(workspace.path),
                cancellationToken: ProcessCancellationToken(),
                onProgress: { _ in }
            )
            Issue.record("expected the dispatch to fail")
        } catch AgentRunnerError.processFailed(let code, let detail) {
            #expect(code == 1)
            #expect(detail.contains("Workspace quota exceeded"))
        }
    }

    @Test(
        "Antigravity: model IDs that already encode effort (-low…-max) are not sent a conflicting --effort",
        arguments: [
            ("gemini-3.8-flash-high", false),
            ("gemini-4-neon-xhigh", false),
            ("gemini-4-neon", true)
        ]
    )
    func agyEffortSuffix(model: String, expectsEffortFlag: Bool) async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let response = #"{\"summary\":\"ok\",\"recommendedVerdict\":\"COMMENT\",\"comments\":[]}"#
        let fake = try FakeAgentCLI(
            in: workspace,
            name: "agy",
            stdoutLines: [#"{"event":"result","result":{"conversation_id":"conv-1","status":"SUCCESS","response":"\#(response)"}}"#]
        )

        let run = try await AgentSessionRunner().run(
            item: item(),
            plan: ExecutionPlan(engine: .antigravity, model: model, effort: .medium),
            preset: TaskPreset.defaults[0],
            workspaceURL: workspace,
            environmentSnapshot: fake.environmentSnapshot(engine: .antigravity),
            lodyConfig: LodyConfig(),
            cancellationToken: ProcessCancellationToken(),
            onProgress: { _ in }
        )

        #expect(fake.argv.contains("--effort") == expectsEffortFlag)
        #expect(fake.value(after: "--model") == model)
        #expect(run.sessionHandle?.sessionID == "conv-1")
        guard case .codeReview? = run.output else {
            Issue.record("expected agy's nested result.response to be parsed as a code review"); return
        }
    }
}

/// 在宿主进程中临时设置环境变量（用于验证哪些变量会/不会传给 AI 子进程）
func withHostEnvironment<T>(_ variables: [String: String], _ body: () async throws -> T) async rethrows -> T {
    let previous = variables.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
    for (key, value) in variables { setenv(key, value, 1) }
    defer {
        for (key, value) in previous {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
    return try await body()
}
