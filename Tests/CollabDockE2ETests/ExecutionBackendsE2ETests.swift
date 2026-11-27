import Foundation
import Testing
@testable import CollabDockCore

/// SPEC：执行后端拆分（DirectCLIBackend / LodyBackend）。断言来自现有行为（见 ReviewPipelineE2ETests / RealWorldGuardsE2ETests），
/// 只是把入口换成后端接口；Lody 的工作区路由过去写在 AppCoordinator.confirmAndRun 里、从未被测试。
@Suite("E2E SPEC — execution backends", .serialized, .enabled(if: GitSandbox.isGitAvailable))
struct ExecutionBackendsE2ETests {
    private static let review = #"{"summary":"ok","recommendedVerdict":"COMMENT","comments":[]}"#

    // MARK: DirectCLIBackend

    @Test("Direct backend: prepares an isolated worktree (plus incremental diff for a continued review) without touching the user's checkout")
    func directPrepareWorkspace() async throws {
        let scenario = try await PRScenario.make()
        defer { scenario.sandbox.cleanup() }
        let firstHead = scenario.headSHA
        let fixed = PRScenario.prFile.replacingOccurrences(of: "    func purge() { }", with: "    mutating func purge() { storage.removeAll() }")
        let newHead = try await scenario.authorPushes(content: fixed, message: "fix: purge clears storage")
        let previous = PreviousReviewContext(previousItemID: "r1", reviewedHeadSHA: firstHead, reviewedAt: Date(), engine: .claudeCode, sessionID: "sess-1")
        let item = scenario.item(headSHA: newHead, previousReview: previous)
        let fake = try FakeAgentCLI(in: scenario.sandbox.root, stdoutLines: [])
        let backend = DirectCLIBackend(worktreeManager: scenario.worktreeManager)

        let context = try await backend.prepareWorkspace(
            for: WorkspacePreparationRequest(
                item: item,
                plan: ExecutionPlan(engine: .claudeCode, model: "sonnet", continuityMode: .continueSessionIncremental, previousReview: previous),
                preferredLocalPath: scenario.sandbox.userRepo.path,
                environment: fake.environmentSnapshot(engine: .claudeCode)
            ),
            onProgress: { _ in }
        )

        #expect(context.isTemporaryWorktree)
        #expect(try await scenario.sandbox.git(["-C", context.workspaceURL.path, "rev-parse", "HEAD"]) == newHead)
        #expect(context.unifiedDiff?.contains("+    static let ttl = 60") == true)
        #expect(context.incrementalDiff?.contains("+    mutating func purge() { storage.removeAll() }") == true)
        #expect(context.incrementalDiff?.contains("+    static let ttl = 60") == false)
        #expect(try await scenario.sandbox.currentBranch() == "main")
    }

    @Test("Direct backend: a fresh full review ignores the previous SHA (no incremental diff)")
    func directFreshReviewHasNoIncrementalDiff() async throws {
        let scenario = try await PRScenario.make()
        defer { scenario.sandbox.cleanup() }
        let previous = PreviousReviewContext(previousItemID: "r1", reviewedHeadSHA: scenario.headSHA, reviewedAt: Date(), engine: .claudeCode)
        let fake = try FakeAgentCLI(in: scenario.sandbox.root, stdoutLines: [])

        let context = try await DirectCLIBackend(worktreeManager: scenario.worktreeManager).prepareWorkspace(
            for: WorkspacePreparationRequest(
                item: scenario.item(headSHA: scenario.headSHA, previousReview: previous),
                plan: ExecutionPlan(engine: .claudeCode, model: "sonnet", continuityMode: .freshSessionFull, previousReview: previous),
                preferredLocalPath: scenario.sandbox.userRepo.path,
                environment: fake.environmentSnapshot(engine: .claudeCode)
            ),
            onProgress: { _ in }
        )

        #expect(context.incrementalDiff == nil)
    }

    @Test("Direct backend: executes the CLI read-only inside the worktree with host tokens stripped, and parses the structured review")
    func directExecute() async throws {
        let scenario = try await PRScenario.make()
        defer { scenario.sandbox.cleanup() }
        let item = scenario.item(headSHA: scenario.headSHA)
        let context = try await scenario.prepare(item)
        let fake = try FakeAgentCLI(
            in: scenario.sandbox.root,
            stdoutLines: [ClaudeStream.initEvent(sessionID: "sess-d"), ClaudeStream.result(sessionID: "sess-d", structuredOutput: SampleReview.json)]
        )
        let request = AgentRunRequest(
            item: item,
            plan: ExecutionPlan(engine: .claudeCode, model: "sonnet"),
            preset: TaskPreset.defaults[0],
            workspace: context,
            environment: fake.environmentSnapshot(engine: .claudeCode)
        )

        let run = try await withHostEnvironment(RealWorldGuardsE2ETests.inheritedHostVariables) {
            try await DirectCLIBackend(worktreeManager: scenario.worktreeManager).execute(request, onProgress: { _ in })
        }

        guard case .codeReview(let review)? = run.output else { Issue.record("expected a code review"); return }
        #expect(review.comments.count == 2)
        #expect(run.sessionHandle?.sessionID == "sess-d")
        #expect(fake.workingDirectory == realPath(context.workspaceURL.path))
        #expect(fake.value(after: "--permission-mode") == "plan")
        #expect(fake.value(after: "-p")?.contains("<untrusted_pr_diff>") == true)
        #expect(fake.environmentKeys.intersection(RealWorldGuardsE2ETests.inheritedHostVariables.keys).isEmpty)
    }

    @Test("Direct backend: supports exactly the three local CLIs and builds quoted resume commands for each")
    func directResumeCommands() {
        let backend = DirectCLIBackend()
        #expect(backend.supports(engine: .claudeCode) && backend.supports(engine: .codex) && backend.supports(engine: .antigravity))
        #expect(!backend.supports(engine: .lody))

        let dir = "/tmp/it's here"
        let claude = backend.resumeShellCommand(for: AgentSessionHandle(engine: .claudeCode, sessionID: "s1", workspacePath: dir, launchMode: .managedStructuredRun))
        #expect(claude == #"cd '/tmp/it'\''s here' && claude --resume 's1'"#)
        let claudeBG = backend.resumeShellCommand(for: AgentSessionHandle(engine: .claudeCode, sessionID: "s1", workspacePath: dir, launchMode: .nativeBackgroundSession))
        #expect(claudeBG.hasSuffix("claude attach 's1'"))
        #expect(backend.resumeShellCommand(for: AgentSessionHandle(engine: .codex, sessionID: "c1", workspacePath: dir, launchMode: .managedStructuredRun)).hasSuffix("codex resume 'c1'"))
        #expect(backend.resumeShellCommand(for: AgentSessionHandle(engine: .antigravity, sessionID: "g1", workspacePath: dir, launchMode: .managedStructuredRun)).hasSuffix("agy --resume 'g1'"))
    }

    @Test("Runner entry with AgentRunRequest routes by engine and behaves like the direct backend")
    func runnerRequestEntry() async throws {
        let scenario = try await PRScenario.make()
        defer { scenario.sandbox.cleanup() }
        let item = scenario.item(headSHA: scenario.headSHA)
        let context = try await scenario.prepare(item)
        let fake = try FakeAgentCLI(in: scenario.sandbox.root, stdoutLines: [ClaudeStream.result(sessionID: "sess-r", structuredOutput: Self.review)])

        let run = try await AgentSessionRunner().run(
            AgentRunRequest(
                item: item,
                plan: ExecutionPlan(engine: .claudeCode, model: "sonnet"),
                preset: TaskPreset.defaults[0],
                workspace: context,
                environment: fake.environmentSnapshot(engine: .claudeCode)
            )
        )

        #expect(run.sessionHandle?.sessionID == "sess-r")
        guard case .codeReview? = run.output else { Issue.record("expected a code review"); return }
    }

    // MARK: LodyBackend — workspace routing (previously untested AppCoordinator logic)

    private func lodyItem() -> CollaborationItem {
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
            payload: .codeChange(CodeChangePayload(
                repository: "acme/backend", number: 7, baseRef: "main", headRef: "feat/cache",
                headSHA: "abc1234", additions: 1, deletions: 0, changedFiles: 1
            ))
        )
    }

    private func lodyEnvironment() -> EnvironmentSnapshot {
        EnvironmentSnapshot(
            resolvedPATH: "/usr/bin:/bin",
            git: CLIProbeStatus(name: "git", isInstalled: true, executablePath: "/usr/bin/git"),
            gh: CLIProbeStatus(name: "gh", isInstalled: false),
            engines: [:],
            githubAuth: GitHubAuthSnapshot(isAuthenticated: false),
            discoveredModels: [:]
        )
    }

    @Test("Lody: a repo registered as a Lody local project is used in place (native --worktree on the PR branch), refs refreshed, no CollabDock worktree")
    func lodyLocalProjectRouting() async throws {
        let worktrees = FakeWorktreeManager()
        let catalog = LodyCatalogSnapshot(localProjects: [
            LodyLocalProjectOption(id: "lp-1", name: "backend", rootPath: "/Users/dev/code/backend", repositoryFullName: "acme/backend")
        ])
        let backend = LodyBackend(catalog: catalog, worktreeManager: worktrees)
        let plan = ExecutionPlan(engine: .lody, model: "gemini-4-neon", launchMode: .nativeBackgroundSession, useIsolatedWorktree: true)

        let context = try await backend.prepareWorkspace(
            for: WorkspacePreparationRequest(item: lodyItem(), plan: plan, environment: lodyEnvironment()),
            onProgress: { _ in }
        )

        #expect(context.workspaceURL.path == "/Users/dev/code/backend")
        #expect(context.isTemporaryWorktree == false)
        #expect(worktrees.prepareCalls.isEmpty)
        #expect(worktrees.refreshCalls == ["/Users/dev/code/backend"])
        #expect(backend.resolveWorkspaceTarget(for: lodyItem(), plan: plan, workspace: context)
            == .localProject(idOrPath: "lp-1", useWorktree: true, branch: "feat/cache"))

        var direct = plan
        direct.useIsolatedWorktree = false
        #expect(backend.resolveWorkspaceTarget(for: lodyItem(), plan: direct, workspace: context)
            == .localProject(idOrPath: "lp-1", useWorktree: false, branch: nil))
    }

    @Test("Lody: an explicitly chosen directory wins; a continued review computes the incremental diff there instead of refreshing refs")
    func lodyPreferredPathWithIncrementalDiff() async throws {
        let worktrees = FakeWorktreeManager()
        let backend = LodyBackend(catalog: LodyCatalogSnapshot(), worktreeManager: worktrees)
        let previous = PreviousReviewContext(previousItemID: "r1", reviewedHeadSHA: "1111111", reviewedAt: Date(), engine: .lody, sessionID: "lody-1")
        let plan = ExecutionPlan(
            engine: .lody, model: "gemini-4-neon", launchMode: .nativeBackgroundSession,
            continuityMode: .continueSessionIncremental, previousReview: previous
        )

        let context = try await backend.prepareWorkspace(
            for: WorkspacePreparationRequest(item: lodyItem(), plan: plan, preferredLocalPath: "/Users/dev/code/backend-2", environment: lodyEnvironment()),
            onProgress: { _ in }
        )

        #expect(context.workspaceURL.path == "/Users/dev/code/backend-2")
        #expect(context.incrementalDiff == "INC-DIFF")
        #expect(context.incrementalCommitLog == "abc1234 fix: purge")
        #expect(worktrees.incrementalCalls.map(\.previousSHA) == ["1111111"])
        #expect(worktrees.refreshCalls.isEmpty)
        #expect(worktrees.prepareCalls.isEmpty)
        #expect(backend.resolveWorkspaceTarget(for: lodyItem(), plan: plan, workspace: context)
            == .localProject(idOrPath: "/Users/dev/code/backend-2", useWorktree: true, branch: "feat/cache"))
    }

    @Test("Lody: a repo linked in the Lody cloud workspace is dispatched with --repo and never cloned locally")
    func lodyLinkedRepoRouting() async throws {
        let worktrees = FakeWorktreeManager()
        let backend = LodyBackend(catalog: LodyCatalogSnapshot(linkedGitHubRepos: ["acme/backend"]), worktreeManager: worktrees)
        let plan = ExecutionPlan(engine: .lody, model: "gemini-4-neon", launchMode: .nativeBackgroundSession)

        let context = try await backend.prepareWorkspace(
            for: WorkspacePreparationRequest(item: lodyItem(), plan: plan, environment: lodyEnvironment()),
            onProgress: { _ in }
        )

        #expect(worktrees.prepareCalls.isEmpty)
        #expect(context.isTemporaryWorktree == false)
        #expect(backend.resolveWorkspaceTarget(for: lodyItem(), plan: plan, workspace: context)
            == .linkedGitHubRepo(fullName: "acme/backend", branch: "feat/cache"))
    }

    @Test("Lody: an unknown repo falls back to a CollabDock-prepared worktree passed as --local-project <path>")
    func lodyFallbackRouting() async throws {
        let worktrees = FakeWorktreeManager()
        let backend = LodyBackend(catalog: LodyCatalogSnapshot(), worktreeManager: worktrees)
        let plan = ExecutionPlan(engine: .lody, model: "gemini-4-neon", launchMode: .nativeBackgroundSession)

        let context = try await backend.prepareWorkspace(
            for: WorkspacePreparationRequest(item: lodyItem(), plan: plan, environment: lodyEnvironment()),
            onProgress: { _ in }
        )

        #expect(worktrees.prepareCalls.count == 1)
        #expect(context == worktrees.preparedContext)
        #expect(backend.resolveWorkspaceTarget(for: lodyItem(), plan: plan, workspace: context)
            == .preparedLocalPath(worktrees.preparedContext.workspaceURL.path))
    }

    // MARK: LodyBackend — execution

    @Test("Lody: dispatches from the injected neutral cwd with project, branch and sidebar title; inherited session variables stripped")
    func lodyExecute() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-e2e-lodybe-\(UUID().uuidString)", isDirectory: true)
        let neutral = sandbox.appendingPathComponent("neutral-cwd", isDirectory: true)
        let project = sandbox.appendingPathComponent("backend", isDirectory: true)
        try FileManager.default.createDirectory(at: neutral, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fake = try FakeAgentCLI(in: sandbox, name: "lody", stdoutLines: [#"{"ok":true,"sessionId":"lody-sess-9","status":"running"}"#])
        let catalog = LodyCatalogSnapshot(localProjects: [
            LodyLocalProjectOption(id: "lp-1", name: "backend", rootPath: project.path, repositoryFullName: "acme/backend")
        ])
        let backend = LodyBackend(catalog: catalog, worktreeManager: FakeWorktreeManager(), temporaryWorkingDirectory: neutral)
        let request = AgentRunRequest(
            item: lodyItem(),
            plan: ExecutionPlan(engine: .lody, model: "gemini-4-neon", launchMode: .nativeBackgroundSession),
            preset: TaskPreset.defaults[0],
            workspace: PreparedWorkspaceContext(workspaceURL: project),
            environment: fake.environmentSnapshot(engine: .lody)
        )

        let run = try await withHostEnvironment(RealWorldGuardsE2ETests.inheritedHostVariables) {
            try await backend.execute(request, onProgress: { _ in })
        }

        #expect(run.wasBackgroundDispatched)
        #expect(run.sessionHandle?.sessionID == "lody-sess-9")
        #expect(fake.workingDirectory == realPath(neutral.path))
        #expect(Array(fake.argv.prefix(3)) == ["session", "create", "--json"])
        #expect(fake.value(after: "--local-project") == "lp-1")
        #expect(fake.argv.contains("--worktree"))
        #expect(fake.value(after: "--branch") == "feat/cache")
        #expect(fake.value(after: "--title") == "CR #7 feat: add ttl")
        #expect(fake.environmentKeys.intersection(RealWorldGuardsE2ETests.inheritedHostVariables.keys).isEmpty)
    }

    @Test("Lody: binary resolution prefers a global lody and falls back to npx (pinned lody@latest)")
    func lodyBinaryResolution() {
        let backend = LodyBackend()
        func env(lody: String?, path: String) -> EnvironmentSnapshot {
            EnvironmentSnapshot(
                resolvedPATH: path,
                git: CLIProbeStatus(name: "git", isInstalled: true, executablePath: "/usr/bin/git"),
                gh: CLIProbeStatus(name: "gh", isInstalled: false),
                engines: lody.map { [.lody: CLIProbeStatus(name: "lody", isInstalled: true, executablePath: $0)] } ?? [:],
                githubAuth: GitHubAuthSnapshot(isAuthenticated: false),
                discoveredModels: [:]
            )
        }

        let global = backend.resolveBinary(environment: env(lody: "/opt/homebrew/bin/lody", path: "/usr/bin")) { $0 == "/opt/homebrew/bin/lody" }
        #expect(global.executablePath == "/opt/homebrew/bin/lody")
        #expect(global.usesNPXFallback == false)

        let npx = backend.resolveBinary(environment: env(lody: nil, path: "/usr/local/bin:/usr/bin")) { $0 == "/usr/local/bin/npx" }
        #expect(npx.executablePath == "/usr/local/bin/npx")
        #expect(npx.usesNPXFallback)

        let none = backend.resolveBinary(environment: env(lody: nil, path: "/usr/bin")) { _ in false }
        #expect(none.executablePath == nil)
    }

    @Test("Lody: deep link / resume command open the session in Lody Desktop; sidebar titles stay compact")
    func lodyLinksAndTitles() {
        let backend = LodyBackend(config: LodyConfig(workspace: "ws-1"))
        let handle = AgentSessionHandle(engine: .lody, sessionID: "s-1", workspacePath: "/tmp", launchMode: .nativeBackgroundSession)

        #expect(backend.sessionDeepLink(for: handle) == URL(string: "lody://session/s-1?workspace=ws-1"))
        #expect(backend.resumeShellCommand(for: handle) == "open 'lody://session/s-1?workspace=ws-1'")
        #expect(backend.formatSessionTitle(for: lodyItem(), hasDedicatedProject: true) == "CR #7 feat: add ttl")
        #expect(backend.formatSessionTitle(for: lodyItem(), hasDedicatedProject: false) == "CR backend #7 feat: add ttl")
    }
}
