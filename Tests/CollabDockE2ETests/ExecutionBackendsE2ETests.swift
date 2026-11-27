import Foundation
import Testing
@testable import CollabDockCore

/// Lody 执行后端：工作区路由（本地项目 / 指定目录 / 云端关联仓库 / CollabDock 兜底 worktree）、派发、二进制定位与深链。
/// 直连 CLI 后端已移除。
@Suite("E2E — Lody execution backend", .serialized, .enabled(if: GitSandbox.isGitAvailable))
struct ExecutionBackendsE2ETests {
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
