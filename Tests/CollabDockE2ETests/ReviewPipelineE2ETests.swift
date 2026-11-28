import Foundation
import Testing
@testable import CollabDockCore

/// 安全网：只剩 Lody 之后的完整链路。GitHub 通知 → 规则 → Lody 工作区（用户仓库就地 + Lody 原生 worktree）→ 假 lody CLI 派发 → 被跟踪的会话。
/// CollabDock 自己不再往 GitHub 写任何东西（评论由 Lody 里的 agent 按用户指示发出）。
@Suite(
    "E2E — PR review pipeline: GitHub → rules → Lody workspace → lody CLI → tracked session",
    .serialized,
    .enabled(if: GitSandbox.isGitAvailable)
)
struct ReviewPipelineE2ETests {
    /// 当前界面语言下的内置模板，渲染 `{{pr_url}}` 后就是 Lody 应收到的完整消息
    static func rendered(_ kind: PromptTemplateKind, for item: CollaborationItem) -> String {
        TaskPreset.defaultTemplate(for: kind, language: CoreL10n.currentLanguage)
            .replacingOccurrences(of: "{{pr_url}}", with: item.url.absoluteString)
    }

    private static let lodyOK = #"{"ok":true,"sessionId":"lody-sess-1","status":"running"}"#

    private func neutralDirectory(in scenario: PRScenario) throws -> URL {
        let dir = scenario.sandbox.root.appendingPathComponent("neutral-cwd", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// CollabDock 只读 GitHub：除 GraphQL 查询外不能有任何写请求
    private func expectNoGitHubWrites(_ github: FakeGitHub) {
        let writes = github.requests.filter { $0.method != "GET" && $0.path != "/graphql" }
        #expect(writes.isEmpty, "CollabDock must not write to GitHub: \(writes.map { "\($0.method) \($0.path)" })")
    }

    @Test("First review: a review request is dispatched to a Lody session on the user's repo (Lody's own worktree), checkout untouched, nothing written to GitHub")
    func firstReviewEndToEnd() async throws {
        let scenario = try await PRScenario.make()
        defer { scenario.sandbox.cleanup() }

        // 1. 拉取：通知 → PR 详情 → 收件箱候选
        let batch = try await scenario.connector.poll(cursor: nil)
        #expect(batch.candidates.count == 1)
        let candidate = try #require(batch.candidates.first)
        let item = candidate.item
        guard case .codeChange(let code) = item.payload else {
            Issue.record("expected a code-change payload"); return
        }
        #expect(code.headSHA == scenario.headSHA)
        #expect(item.triggerKind == .reviewRequested)

        // 2. 规则引擎：默认规则接受「指派给我 Review」
        let evaluation = TriggerRuleEngine().evaluate(
            event: candidate.event,
            currentHandle: PRScenario.reviewer,
            rules: TriggerRules()
        )
        guard case .accept = evaluation else {
            Issue.record("default rules should accept a review request, got \(evaluation)"); return
        }

        // 3. Lody 工作区：用户仓库就地使用（Lody 自己开 worktree），只刷新 PR 分支引用
        let fake = try FakeAgentCLI(in: scenario.sandbox.root, name: "lody", stdoutLines: [Self.lodyOK])
        let environment = fake.environmentSnapshot(engine: .lody)
        let backend = LodyBackend(
            catalog: LodyCatalogSnapshot(),
            worktreeManager: scenario.worktreeManager,
            temporaryWorkingDirectory: try neutralDirectory(in: scenario)
        )
        let plan = ExecutionPlan(engine: .lody, model: "default", launchMode: .nativeBackgroundSession, useIsolatedWorktree: true)
        let context = try await backend.prepareWorkspace(
            for: WorkspacePreparationRequest(
                item: item, plan: plan, preferredLocalPath: scenario.sandbox.userRepo.path, environment: environment
            ),
            onProgress: { _ in }
        )
        #expect(realPath(context.workspaceURL.path) == realPath(scenario.sandbox.userRepo.path))
        #expect(context.isTemporaryWorktree == false)

        #expect(try await scenario.sandbox.currentBranch() == "main")
        let status = try await scenario.sandbox.git(["-C", scenario.sandbox.userRepo.path, "status", "--porcelain"])
        #expect(status == "?? WIP.txt")
        let wip = try String(contentsOf: scenario.sandbox.userRepo.appendingPathComponent("WIP.txt"), encoding: .utf8)
        #expect(wip == "my uncommitted work\n")

        // 4. 派发：假 lody 记录收到的参数 / 环境 / 工作目录
        let run = try await withHostGitHubTokens {
            try await backend.execute(
                AgentRunRequest(item: item, plan: plan, preset: TaskPreset.defaults[0], workspace: context, environment: environment),
                onProgress: { _ in }
            )
        }

        #expect(run.wasBackgroundDispatched)
        #expect(run.output == nil)
        #expect(run.sessionHandle?.engine == .lody)
        #expect(run.sessionHandle?.sessionID == "lody-sess-1")
        #expect(Array(fake.argv.prefix(3)) == ["session", "create", "--json"])
        #expect(fake.value(after: "--local-project") == scenario.sandbox.userRepo.path)
        #expect(fake.argv.contains("--worktree"))
        #expect(fake.value(after: "--branch") == PRScenario.headRef)
        let prompt = try #require(fake.argv.last)
        // 发给 Lody 的只有首次审查模板 + PR 链接（见 UserPromptTemplateSpecTests）
        #expect(prompt == Self.rendered(.firstReview, for: item))
        #expect(!prompt.contains(PRScenario.token))
        #expect(fake.workingDirectory != realPath(scenario.sandbox.userRepo.path), "lody must not start inside the target repository")
        let leakedKeys = fake.environmentKeys.intersection(["GITHUB_TOKEN", "GH_TOKEN", "GH_ENTERPRISE_TOKEN"])
        #expect(leakedKeys.isEmpty)

        // 5. CollabDock 没有往 GitHub 写任何东西
        expectNoGitHubWrites(scenario.github)
    }

    @Test("The same review request seen again after a restart is deduplicated by its stable key")
    func dedupeAcrossRestart() async throws {
        let scenario = try await PRScenario.make()
        defer { scenario.sandbox.cleanup() }
        let dbPath = scenario.sandbox.root.appendingPathComponent("collabdock.sqlite").path

        let first = try #require(try await scenario.connector.poll(cursor: nil).candidates.first)
        do {
            let store = try SQLiteTaskStore(databasePath: dbPath)
            try await store.markSeen(dedupeKey: first.dedupeKey, itemID: first.item.id)
            try await store.upsertItem(first.item)
        }

        // App 重启后再次轮询到同一事件
        let again = try #require(try await scenario.connector.poll(cursor: nil).candidates.first)
        let reopened = try SQLiteTaskStore(databasePath: dbPath)
        #expect(again.dedupeKey == first.dedupeKey)
        #expect(try await reopened.hasSeen(dedupeKey: again.dedupeKey))
        #expect(try await reopened.loadAllItems().map(\.id) == [first.item.id])
    }

    @Test("Re-review after a fix push: the incremental range is computed in the repo and the previous Lody session is continued")
    func incrementalReReviewContinuesLodySession() async throws {
        let scenario = try await PRScenario.make()
        defer { scenario.sandbox.cleanup() }
        let firstHead = scenario.headSHA

        let fixedFile = PRScenario.prFile.replacingOccurrences(
            of: "    func purge() { }",
            with: "    mutating func purge() { storage.removeAll() }"
        )
        let newHead = try await scenario.authorPushes(content: fixedFile, message: "fix: purge clears storage")

        let previous = PreviousReviewContext(
            previousItemID: scenario.item(headSHA: firstHead).id,
            reviewedHeadSHA: firstHead,
            reviewedAt: Date(),
            engine: .lody,
            sessionID: "lody-sess-1",
            summarySnippet: "purge() is a no-op",
            reviewRound: 1
        )
        let item = scenario.item(headSHA: newHead, previousReview: previous)
        let plan = ExecutionPlan(
            engine: .lody, model: "default", launchMode: .nativeBackgroundSession,
            continuityMode: .continueSessionIncremental, previousReview: previous
        )
        let fake = try FakeAgentCLI(in: scenario.sandbox.root, name: "lody", stdoutLines: [Self.lodyOK])
        let environment = fake.environmentSnapshot(engine: .lody)
        let backend = LodyBackend(
            catalog: LodyCatalogSnapshot(),
            worktreeManager: scenario.worktreeManager,
            temporaryWorkingDirectory: try neutralDirectory(in: scenario)
        )

        let context = try await backend.prepareWorkspace(
            for: WorkspacePreparationRequest(
                item: item, plan: plan, preferredLocalPath: scenario.sandbox.userRepo.path, environment: environment
            ),
            onProgress: { _ in }
        )
        #expect(context.wasForcePushed == false)
        let incremental = try #require(context.incrementalDiff)
        #expect(incremental.contains("+    mutating func purge() { storage.removeAll() }"))
        #expect(!incremental.contains("+    static let ttl = 60"), "round-1 changes must not be re-reviewed")
        #expect(context.incrementalCommitLog?.contains("fix: purge clears storage") == true)

        let run = try await backend.execute(
            AgentRunRequest(item: item, plan: plan, preset: TaskPreset.defaults[0], workspace: context, environment: environment),
            onProgress: { _ in }
        )

        #expect(Array(fake.argv.prefix(3)) == ["session", "chat", "--json"])
        #expect(fake.argv.contains("lody-sess-1"))
        let prompt = try #require(fake.argv.last)
        // 续聊消息只有复审模板 + PR 链接：agent 在原会话里自己拉取、对比新提交，CollabDock 不再附带提交范围、命令或 diff
        #expect(prompt == Self.rendered(.followUp, for: item))
        #expect(run.sessionHandle?.sessionID == "lody-sess-1")
        expectNoGitHubWrites(scenario.github)
    }

    @Test("Re-review whose previous round ran on a removed direct engine opens a new Lody session")
    func reReviewAfterDirectEngineStartsNewLodySession() async throws {
        let scenario = try await PRScenario.make()
        defer { scenario.sandbox.cleanup() }
        let previous = PreviousReviewContext(
            previousItemID: scenario.item(headSHA: scenario.headSHA).id,
            reviewedHeadSHA: scenario.headSHA,
            reviewedAt: Date(),
            engine: .claudeCode,
            sessionID: "claude-sess-1",
            reviewRound: 1
        )
        let item = scenario.item(headSHA: scenario.headSHA, previousReview: previous)
        let plan = ExecutionPlan(
            engine: .lody, model: "default", launchMode: .nativeBackgroundSession,
            continuityMode: .continueSessionIncremental, previousReview: previous
        )
        let fake = try FakeAgentCLI(in: scenario.sandbox.root, name: "lody", stdoutLines: [Self.lodyOK])
        let backend = LodyBackend(
            catalog: LodyCatalogSnapshot(),
            worktreeManager: scenario.worktreeManager,
            temporaryWorkingDirectory: try neutralDirectory(in: scenario)
        )

        _ = try await backend.execute(
            AgentRunRequest(
                item: item, plan: plan, preset: TaskPreset.defaults[0],
                workspace: PreparedWorkspaceContext(workspaceURL: scenario.sandbox.userRepo),
                environment: fake.environmentSnapshot(engine: .lody)
            ),
            onProgress: { _ in }
        )

        #expect(Array(fake.argv.prefix(3)) == ["session", "create", "--json"])
        #expect(!fake.argv.contains("claude-sess-1"))
    }

    @Test("Re-review after a force-push falls back to the full PR diff")
    func forcePushFallsBackToFullDiff() async throws {
        let scenario = try await PRScenario.make()
        defer { scenario.sandbox.cleanup() }
        let firstHead = scenario.headSHA

        let rewritten = PRScenario.baseFile.replacingOccurrences(
            of: "}\n",
            with: "    static let ttl = 120\n}\n"
        )
        let newHead = try await scenario.authorPushes(content: rewritten, message: "feat: ttl (rebased)", rewriteHistory: true)

        let context = try await scenario.prepare(scenario.item(headSHA: newHead), previousReviewedSHA: firstHead)
        #expect(context.wasForcePushed)
        #expect(context.incrementalDiff?.contains("+    static let ttl = 120") == true)
    }
}

/// 在宿主进程里放入 GitHub Token 环境变量，验证它们不会被传给 AI 子进程
func withHostGitHubTokens<T>(_ body: () async throws -> T) async rethrows -> T {
    let keys = ["GITHUB_TOKEN", "GH_TOKEN", "GH_ENTERPRISE_TOKEN"]
    let previous = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
    for key in keys { setenv(key, "ghp_host_secret_must_not_leak", 1) }
    defer {
        for (key, value) in previous {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
    return try await body()
}

/// `URL.resolvingSymlinksInPath()` 会把 /private/var 折叠成 /var；这里用 realpath 与 `pwd -P` 保持一致
func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
