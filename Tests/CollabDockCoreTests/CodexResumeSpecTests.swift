import Foundation
import Testing
@testable import CollabDockCore

/// SPEC：Codex 续聊复审（`codex exec resume <SESSION_ID> <PROMPT>`）。
///
/// 依据 codex-cli 0.159 的 `codex exec resume --help`：resume 子命令支持 `-m`、`-c`、`--json`、`--output-schema`、`-o`，
/// 但**不支持** `--sandbox` / `-C`。因此续聊时只读沙箱必须用 `-c sandbox_mode="..."` 传入，工作目录靠进程 cwd。
@Suite("SPEC — Codex session continuation for incremental re-review")
struct CodexResumeSpecTests {
    private let sessionID = "0199c3a2-7b1e-7f30-9a4d-5e2f8c61d0b7"
    private let workspace = URL(fileURLWithPath: "/tmp/collabdock-codex-wt", isDirectory: true)
    private let schema = URL(fileURLWithPath: "/tmp/collabdock-codex-run/schema.json")
    private let lastMessage = URL(fileURLWithPath: "/tmp/collabdock-codex-run/last-message.json")

    private func previous(engine: AgentEngine = .codex, sessionID: String? = "0199c3a2-7b1e-7f30-9a4d-5e2f8c61d0b7") -> PreviousReviewContext {
        PreviousReviewContext(
            previousItemID: "r1", reviewedHeadSHA: "1111111", reviewedAt: Date(),
            engine: engine, model: "gpt-5.3-codex", sessionID: sessionID, reviewRound: 1
        )
    }

    private func command(plan: ExecutionPlan, prompt: String = "REVIEW-PROMPT") throws -> AgentCommandSpec {
        let item = Fixtures.prItem(status: .pendingConfirmation)
        let request = AgentRunRequest(
            item: item,
            plan: plan,
            preset: TaskPreset.defaults[0],
            workspace: PreparedWorkspaceContext(workspaceURL: workspace, isTemporaryWorktree: true)
        )
        return try DirectCLIBackend().buildCommand(for: request, prompt: prompt, schemaFileURL: schema, outputFileURL: lastMessage)
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private func configOverrides(in args: [String]) -> [String] {
        args.indices.filter { args[$0] == "-c" && $0 + 1 < args.count }.map { args[$0 + 1] }
    }

    @Test("A previous Codex review with a session id can be continued (like Claude / Antigravity / Lody)")
    func codexCanContinueSameSession() {
        #expect(previous().canContinueSameSession)
        #expect(previous(sessionID: nil).canContinueSameSession == false)
        #expect(previous(sessionID: "").canContinueSameSession == false)
    }

    @Test("Continuing a Codex review uses `codex exec resume <id> <prompt>` with structured output and the chosen model/effort")
    func continuedCodexCommand() throws {
        let spec = try command(plan: ExecutionPlan(
            engine: .codex, model: "gpt-5.3-codex", effort: .high,
            continuityMode: .continueSessionIncremental, previousReview: previous()
        ))
        let args = spec.arguments

        #expect(Array(args.prefix(2)) == ["exec", "resume"])
        #expect(args.last == "REVIEW-PROMPT")
        #expect(args.dropLast().last == sessionID, "session id must be the positional argument right before the prompt")
        #expect(args.contains("--json"))
        #expect(value(after: "--output-schema", in: args) == schema.path)
        #expect(value(after: "-o", in: args) == lastMessage.path)
        #expect(value(after: "-m", in: args) == "gpt-5.3-codex")
        #expect(configOverrides(in: args).contains(#"model_reasoning_effort="high""#))
        #expect(spec.outputFilePath == lastMessage)
    }

    @Test("Continuing keeps the read-only sandbox via a config override, never via flags `resume` rejects")
    func continuedCodexStaysReadOnly() throws {
        let spec = try command(plan: ExecutionPlan(
            engine: .codex, model: "gpt-5.3-codex",
            continuityMode: .continueSessionIncremental, previousReview: previous()
        ))
        let args = spec.arguments

        #expect(configOverrides(in: args).contains(#"sandbox_mode="read-only""#))
        for unsupported in ["--sandbox", "-s", "-C", "--cd"] {
            #expect(!args.contains(unsupported), "`codex exec resume` does not accept \(unsupported)")
        }
        #expect(spec.workingDirectory == workspace, "without -C the worktree must be the process working directory")
    }

    @Test("A mode explicitly chosen by the user is carried into the resumed session's sandbox override")
    func continuedCodexRespectsChosenMode() throws {
        let spec = try command(plan: ExecutionPlan(
            engine: .codex, model: "gpt-5.3-codex", mode: "workspace-write",
            continuityMode: .continueSessionIncremental, previousReview: previous()
        ))
        #expect(configOverrides(in: spec.arguments).contains(#"sandbox_mode="workspace-write""#))
    }

    @Test(
        "Fresh Codex runs are unchanged: no resume when the user picks a new session, the previous engine differs, or there is no session id",
        arguments: [
            ("fresh session", ReviewContinuityMode.freshSessionIncremental, AgentEngine.codex, true),
            ("full review", ReviewContinuityMode.freshSessionFull, AgentEngine.codex, true),
            ("other engine", ReviewContinuityMode.continueSessionIncremental, AgentEngine.claudeCode, true),
            ("no session id", ReviewContinuityMode.continueSessionIncremental, AgentEngine.codex, false)
        ]
    )
    func freshCodexCommandUnchanged(label: String, continuity: ReviewContinuityMode, previousEngine: AgentEngine, hasSession: Bool) throws {
        let spec = try command(plan: ExecutionPlan(
            engine: .codex, model: "gpt-5.3-codex",
            continuityMode: continuity, previousReview: previous(engine: previousEngine, sessionID: hasSession ? sessionID : nil)
        ))
        let args = spec.arguments

        #expect(args.first == "exec")
        #expect(!args.contains("resume"), "\(label): must start a new session")
        #expect(value(after: "--sandbox", in: args) == "read-only")
        #expect(value(after: "-C", in: args) == workspace.path)
        #expect(args.last == "REVIEW-PROMPT")
    }
}
