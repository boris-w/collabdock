import Foundation
import Testing
@testable import CollabDockCore

/// 安全网（Characterization）：在现有代码上必须为绿。重构 AppCoordinator / 执行后端时，这些断言描述的外部行为不能变。
@Suite(
    "E2E — PR review pipeline: GitHub → rules → isolated worktree → agent CLI → pending review",
    .serialized,
    .enabled(if: GitSandbox.isGitAvailable)
)
struct ReviewPipelineE2ETests {
    @Test("First review: a review request becomes a pending GitHub review draft without touching the user's checkout")
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

        // 3. 隔离上下文：detached worktree 指向 PR 头，用户仓库原封不动
        let context = try await scenario.prepare(item)
        #expect(context.isTemporaryWorktree)
        #expect(context.workspaceURL.path.hasPrefix(scenario.sandbox.cacheRoot.path))
        let worktreeHead = try await scenario.sandbox.git(["-C", context.workspaceURL.path, "rev-parse", "HEAD"])
        #expect(worktreeHead == scenario.headSHA)
        let diff = try #require(context.unifiedDiff)
        #expect(diff.contains("+    static let ttl = 60"))
        #expect(diff.contains("+    func purge() { }"))

        #expect(try await scenario.sandbox.currentBranch() == "main")
        let status = try await scenario.sandbox.git(["-C", scenario.sandbox.userRepo.path, "status", "--porcelain"])
        #expect(status == "?? WIP.txt")
        let wip = try String(contentsOf: scenario.sandbox.userRepo.appendingPathComponent("WIP.txt"), encoding: .utf8)
        #expect(wip == "my uncommitted work\n")

        // 4. 执行：假 claude 回放 stream-json
        let fake = try FakeAgentCLI(
            in: scenario.sandbox.root,
            stdoutLines: [
                ClaudeStream.initEvent(sessionID: "sess-e2e-1"),
                ClaudeStream.toolUse("Read", path: PRScenario.filePath),
                ClaudeStream.result(sessionID: "sess-e2e-1", structuredOutput: SampleReview.json)
            ]
        )
        let plan = ExecutionPlan(engine: .claudeCode, model: "sonnet", effort: .medium)
        let progress = ProgressLog()
        let run = try await withHostGitHubTokens {
            try await AgentSessionRunner().run(
                item: item,
                plan: plan,
                preset: TaskPreset.defaults[0],
                workspaceURL: context.workspaceURL,
                environmentSnapshot: fake.environmentSnapshot(engine: .claudeCode),
                lodyConfig: LodyConfig(),
                unifiedDiff: context.unifiedDiff,
                cancellationToken: ProcessCancellationToken(),
                onProgress: { progress.append($0) }
            )
        }

        #expect(run.wasBackgroundDispatched == false)
        #expect(run.sessionHandle?.sessionID == "sess-e2e-1")
        #expect(run.sessionHandle?.engine == .claudeCode)
        guard case .codeReview(let review)? = run.output else {
            Issue.record("expected a structured code review, got \(String(describing: run.output))"); return
        }
        #expect(review.comments.count == 2)
        #expect(progress.all.contains { $0.contains("Read") || $0.contains("Cache.swift") })

        // 4b. 宿主真正交给 CLI 的东西：只读模式、结构化输出、在隔离 worktree 内运行、拿不到 GitHub Token
        #expect(fake.workingDirectory == realPath(context.workspaceURL.path))
        #expect(fake.value(after: "--permission-mode") == "plan")
        #expect(fake.value(after: "--output-format") == "stream-json")
        #expect(fake.value(after: "--json-schema") != nil)
        let allowedTools = try #require(fake.value(after: "--allowedTools"))
        #expect(allowedTools.contains("Read"))
        #expect(!allowedTools.contains("Write") && !allowedTools.contains("Edit"))
        let leakedKeys = fake.environmentKeys.intersection(["GITHUB_TOKEN", "GH_TOKEN", "GH_ENTERPRISE_TOKEN"])
        #expect(leakedKeys.isEmpty)
        let prompt = try #require(fake.value(after: "-p"))
        #expect(prompt.contains("<untrusted_external_data>"))
        #expect(prompt.contains("<untrusted_pr_diff>"))
        #expect(prompt.contains("+    static let ttl = 60"))
        #expect(!prompt.contains(PRScenario.token))

        // 5. 回写：Pending Review 草稿（不带 event），越界评论降级进总结，本地报告落盘
        let reports = scenario.sandbox.root.appendingPathComponent("reports", isDirectory: true)
        let receipt = try await scenario.connector.deliver(
            output: .codeReview(review),
            for: item,
            mode: .platformDraft,
            plan: plan,
            unifiedDiff: context.unifiedDiff,
            reportsDirectory: reports
        )
        #expect(receipt.deliveredMode == .platformDraft)

        let posts = scenario.github.requests("POST", "/repos/\(PRScenario.repository)/pulls/\(PRScenario.number)/reviews")
        #expect(posts.count == 1)
        let body = try #require(posts.first?.jsonBody)
        #expect(body["event"] == nil, "a pending draft must not carry an event")
        #expect(body["commit_id"] as? String == scenario.headSHA)
        let comments = try #require(body["comments"] as? [[String: Any]])
        #expect(comments.count == 1)
        #expect(comments.first?["path"] as? String == PRScenario.filePath)
        #expect(comments.first?["line"] as? Int == SampleReview.inDiffLine)
        #expect((comments.first?["body"] as? String)?.contains("```suggestion") == true)
        #expect((body["body"] as? String)?.contains("Out-of-diff note") == true)
        #expect(posts.first?.headers["Authorization"]?.contains(PRScenario.token) == true)

        let reportPath = try #require(receipt.localReportPath)
        let report = try String(contentsOf: reportPath, encoding: .utf8)
        #expect(report.contains("Adds a TTL constant"))

        // 6. 清理 worktree 后不留痕迹
        await scenario.worktreeManager.removeWorktree(
            baseRepositoryURL: scenario.sandbox.userRepo,
            worktreeURL: context.workspaceURL,
            gitExecutablePath: scenario.sandbox.gitPath,
            environment: scenario.sandbox.env
        )
        #expect(!FileManager.default.fileExists(atPath: context.workspaceURL.path))
        let worktrees = try await scenario.sandbox.git(["-C", scenario.sandbox.userRepo.path, "worktree", "list", "--porcelain"])
        #expect(!worktrees.contains(context.workspaceURL.lastPathComponent))
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

    @Test("Re-review after a fix push: incremental diff + resume of the previous agent session")
    func incrementalReReviewResumesSession() async throws {
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
            engine: .claudeCode,
            model: "sonnet",
            sessionID: "sess-e2e-1",
            summarySnippet: "purge() is a no-op",
            reviewRound: 1
        )
        let item = scenario.item(headSHA: newHead, previousReview: previous)

        let context = try await scenario.prepare(item, previousReviewedSHA: firstHead)
        #expect(context.wasForcePushed == false)
        let incremental = try #require(context.incrementalDiff)
        #expect(incremental.contains("+    mutating func purge() { storage.removeAll() }"))
        #expect(!incremental.contains("+    static let ttl = 60"), "round-1 changes must not be re-reviewed")
        #expect(context.incrementalCommitLog?.contains("fix: purge clears storage") == true)
        #expect(context.unifiedDiff?.contains("+    static let ttl = 60") == true)

        let fake = try FakeAgentCLI(
            in: scenario.sandbox.root,
            stdoutLines: [ClaudeStream.result(sessionID: "sess-e2e-1", structuredOutput: #"{"summary":"Fix looks good.","recommendedVerdict":"APPROVE","comments":[]}"#)]
        )
        let plan = ExecutionPlan(
            engine: .claudeCode,
            model: "sonnet",
            continuityMode: .continueSessionIncremental,
            previousReview: previous
        )
        let run = try await AgentSessionRunner().run(
            item: item,
            plan: plan,
            preset: TaskPreset.defaults[0],
            workspaceURL: context.workspaceURL,
            environmentSnapshot: fake.environmentSnapshot(engine: .claudeCode),
            lodyConfig: LodyConfig(),
            unifiedDiff: context.unifiedDiff,
            incrementalDiff: context.incrementalDiff,
            incrementalCommitLog: context.incrementalCommitLog,
            wasForcePushed: context.wasForcePushed,
            cancellationToken: ProcessCancellationToken(),
            onProgress: { _ in }
        )

        #expect(fake.value(after: "--resume") == "sess-e2e-1")
        let prompt = try #require(fake.value(after: "-p"))
        #expect(prompt.contains("<untrusted_incremental_diff>"))
        #expect(prompt.contains("+    mutating func purge() { storage.removeAll() }"))
        #expect(run.sessionHandle?.sessionID == "sess-e2e-1")
        guard case .codeReview(let review)? = run.output else {
            Issue.record("expected a structured code review"); return
        }
        #expect(review.recommendedVerdict == .approve)
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
