import Foundation
import Testing
@testable import CollabDockCore

@Suite("E2E — agent process lifecycle: failure reporting and user cancellation", .serialized)
struct AgentRunnerLifecycleE2ETests {
    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-e2e-run-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
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

    private func lodyPlan() -> ExecutionPlan {
        ExecutionPlan(engine: .lody, model: "default", launchMode: .nativeBackgroundSession)
    }

    @Test("An expired Lody login is reported with the raw reason and a login hint instead of a bare exit code")
    func cliFailureIsReported() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fake = try FakeAgentCLI(
            in: workspace,
            name: "lody",
            stdoutLines: [],
            exitCode: 1,
            stderr: "Error: token expired, please run lody login"
        )

        do {
            _ = try await AgentSessionRunner().run(
                item: item(),
                plan: lodyPlan(),
                preset: TaskPreset.defaults[0],
                workspaceURL: workspace,
                environmentSnapshot: fake.environmentSnapshot(engine: .lody),
                lodyConfig: LodyConfig(),
                lodyWorkspaceTarget: .preparedLocalPath(workspace.path),
                cancellationToken: ProcessCancellationToken(),
                onProgress: { _ in }
            )
            Issue.record("expected the run to fail")
        } catch let error as AgentRunnerError {
            guard case .processFailed(let code, let detail) = error else {
                Issue.record("expected processFailed, got \(error)"); return
            }
            #expect(code == 1)
            #expect(detail.contains("token expired"))
            #expect(detail.contains("lody@latest login"))
        }
    }

    @Test("Neither lody nor npx on PATH: the dispatch fails fast with an actionable error")
    func missingBinary() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let env = EnvironmentSnapshot(
            resolvedPATH: workspace.path, // 空目录：找不到 lody 也找不到 npx
            git: CLIProbeStatus(name: "git", isInstalled: true, executablePath: "/usr/bin/git"),
            gh: CLIProbeStatus(name: "gh", isInstalled: false),
            engines: [:],
            githubAuth: GitHubAuthSnapshot(isAuthenticated: false),
            discoveredModels: [:]
        )

        await #expect(throws: AgentRunnerError.self) {
            _ = try await AgentSessionRunner().run(
                item: item(),
                plan: lodyPlan(),
                preset: TaskPreset.defaults[0],
                workspaceURL: workspace,
                environmentSnapshot: env,
                lodyConfig: LodyConfig(),
                lodyWorkspaceTarget: .preparedLocalPath(workspace.path),
                cancellationToken: ProcessCancellationToken(),
                onProgress: { _ in }
            )
        }
    }

    /// 真实 CLI（lody 走 node / npx）会派生子进程并继承 stdout。用户点「中止」后，整个进程树都必须结束，
    /// 且 run 要在几秒内以 `.cancelled` 返回，而不是等到子进程自己退出、管道关闭才返回。
    @Test(
        "Cancelling kills the whole agent process tree and returns promptly",
        .timeLimit(.minutes(1))
    )
    func cancellationKillsProcessTree() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fake = try FakeAgentCLI(
            in: workspace,
            name: "lody",
            stdoutLines: [#"{"ok":true,"sessionId":"lody-cancel","status":"running"}"#],
            hangSeconds: 20
        )
        let token = ProcessCancellationToken()
        let runItem = item()
        let snapshot = fake.environmentSnapshot(engine: .lody)
        let target = LodyWorkspaceTarget.preparedLocalPath(workspace.path)
        let plan = lodyPlan()

        let task = Task {
            try await AgentSessionRunner().run(
                item: runItem,
                plan: plan,
                preset: TaskPreset.defaults[0],
                workspaceURL: workspace,
                environmentSnapshot: snapshot,
                lodyConfig: LodyConfig(),
                lodyWorkspaceTarget: target,
                cancellationToken: token,
                onProgress: { _ in }
            )
        }

        // 等假 CLI 真正跑起来（含它派生的子进程）
        for _ in 0..<100 where fake.recordedPID("child_pid") == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let agentPID = try #require(fake.recordedPID())
        let childPID = try #require(fake.recordedPID("child_pid"))
        #expect(isProcessAlive(agentPID) && isProcessAlive(childPID), "fake agent should be running before cancel")

        let cancelledAt = Date()
        token.cancel()
        let outcome = await task.result
        let elapsed = Date().timeIntervalSince(cancelledAt)

        switch outcome {
        case .success:
            Issue.record("a cancelled run must not succeed")
        case .failure(let error):
            guard case AgentRunnerError.cancelled = error else {
                Issue.record("expected AgentRunnerError.cancelled, got \(error)"); break
            }
        }
        #expect(elapsed < 5, "run returned \(Int(elapsed))s after cancel; expected < 5s")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!isProcessAlive(agentPID), "agent process \(agentPID) still alive")
        #expect(!isProcessAlive(childPID), "agent child process \(childPID) still alive (orphaned)")
        if isProcessAlive(childPID) { kill(childPID, SIGKILL) }
    }
}
