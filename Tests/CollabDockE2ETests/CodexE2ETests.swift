import Foundation
import Testing
@testable import CollabDockCore

/// Codex 直连 CLI 的端到端行为：假 `codex` 回放 `--json` 事件流，并把最终消息写入 `-o <file>`（与真实 codex 一致）。
@Suite("E2E — Codex CLI: first review and continued re-review", .serialized, .enabled(if: GitSandbox.isGitAvailable))
struct CodexE2ETests {
    static let threadID = "0199c3a2-7b1e-7f30-9a4d-5e2f8c61d0b7"

    private func codexStream(threadID: String = CodexE2ETests.threadID) -> [String] {
        [
            #"{"type":"thread.started","thread_id":"\#(threadID)"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"see last message file"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":0,"output_tokens":300}}"#
        ]
    }

    @Test("First Codex review: read-only sandbox, runs in the worktree, structured result read from -o, thread id kept for resume")
    func firstCodexReview() async throws {
        let scenario = try await PRScenario.make()
        defer { scenario.sandbox.cleanup() }
        let item = scenario.item(headSHA: scenario.headSHA)
        let context = try await scenario.prepare(item)
        let fake = try FakeAgentCLI(
            in: scenario.sandbox.root,
            name: "codex",
            stdoutLines: codexStream(),
            outputFileFlag: "-o",
            outputFileContent: SampleReview.json
        )

        let run = try await withHostEnvironment(RealWorldGuardsE2ETests.inheritedHostVariables) {
            try await DirectCLIBackend(worktreeManager: scenario.worktreeManager).execute(
                AgentRunRequest(
                    item: item,
                    plan: ExecutionPlan(engine: .codex, model: "gpt-5.3-codex"),
                    preset: TaskPreset.defaults[0],
                    workspace: context,
                    environment: fake.environmentSnapshot(engine: .codex)
                ),
                onProgress: { _ in }
            )
        }

        #expect(fake.argv.first == "exec")
        #expect(!fake.argv.contains("resume"))
        #expect(fake.value(after: "--sandbox") == "read-only")
        #expect(fake.value(after: "-C") == context.workspaceURL.path)
        #expect(fake.workingDirectory == realPath(context.workspaceURL.path))
        #expect(fake.argv.last?.contains("<untrusted_pr_diff>") == true)
        #expect(fake.environmentKeys.intersection(RealWorldGuardsE2ETests.inheritedHostVariables.keys).isEmpty)
        #expect(run.sessionHandle?.sessionID == Self.threadID)
        guard case .codeReview(let review)? = run.output else {
            Issue.record("expected the -o file to be parsed as a code review, got \(String(describing: run.output))"); return
        }
        #expect(review.comments.count == 2)
    }

    /// SPEC（实现前为红）：开发者推送修复后，用 Codex 续聊上一轮会话做增量复审。
    @Test("SPEC: continued Codex re-review resumes the previous thread with only the incremental diff")
    func continuedCodexReReview() async throws {
        let scenario = try await PRScenario.make()
        defer { scenario.sandbox.cleanup() }
        let firstHead = scenario.headSHA
        let fixed = PRScenario.prFile.replacingOccurrences(of: "    func purge() { }", with: "    mutating func purge() { storage.removeAll() }")
        let newHead = try await scenario.authorPushes(content: fixed, message: "fix: purge clears storage")
        let previous = PreviousReviewContext(
            previousItemID: "r1", reviewedHeadSHA: firstHead, reviewedAt: Date(),
            engine: .codex, model: "gpt-5.3-codex", sessionID: Self.threadID, reviewRound: 1
        )
        let item = scenario.item(headSHA: newHead, previousReview: previous)
        let context = try await scenario.prepare(item, previousReviewedSHA: firstHead)
        let fake = try FakeAgentCLI(
            in: scenario.sandbox.root,
            name: "codex",
            stdoutLines: codexStream(),
            outputFileFlag: "-o",
            outputFileContent: #"{"summary":"Fix looks good.","recommendedVerdict":"APPROVE","comments":[]}"#
        )

        let run = try await DirectCLIBackend(worktreeManager: scenario.worktreeManager).execute(
            AgentRunRequest(
                item: item,
                plan: ExecutionPlan(
                    engine: .codex, model: "gpt-5.3-codex",
                    continuityMode: .continueSessionIncremental, previousReview: previous
                ),
                preset: TaskPreset.defaults[0],
                workspace: context,
                environment: fake.environmentSnapshot(engine: .codex)
            ),
            onProgress: { _ in }
        )

        let args = fake.argv
        #expect(Array(args.prefix(2)) == ["exec", "resume"])
        #expect(args.dropLast().last == Self.threadID)
        #expect(!args.contains("--sandbox") && !args.contains("-C"), "`codex exec resume` rejects --sandbox / -C")
        #expect(args.contains(#"sandbox_mode="read-only""#))
        #expect(fake.workingDirectory == realPath(context.workspaceURL.path))
        let prompt = try #require(args.last)
        #expect(prompt.contains("<untrusted_incremental_diff>"))
        #expect(prompt.contains("+    mutating func purge() { storage.removeAll() }"))
        #expect(run.sessionHandle?.sessionID == Self.threadID)
        guard case .codeReview(let review)? = run.output else {
            Issue.record("expected a code review"); return
        }
        #expect(review.recommendedVerdict == .approve)
    }
}
