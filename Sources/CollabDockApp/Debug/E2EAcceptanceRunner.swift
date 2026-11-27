#if DEBUG
import Foundation
import CollabDockCore

/// 仅用于 DEBUG 模式的真实 PR 端到端链路验收器（不编入 Release 包，Lody-only，关联 TASK-014）
public enum E2EAcceptanceRunner {
    public static func runIfRequested() {
        let args = CommandLine.arguments
        guard let prIdx = args.firstIndex(of: "--e2e-pr"), prIdx + 1 < args.count else {
            return
        }
        let prRef = args[prIdx + 1]
        let agentOverride: String? = {
            if let idx = args.firstIndex(of: "--agent"), idx + 1 < args.count {
                return args[idx + 1]
            }
            return nil
        }()
        let modelOverride: String? = {
            if let idx = args.firstIndex(of: "--model"), idx + 1 < args.count {
                return args[idx + 1]
            }
            return nil
        }()

        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await execute(
                    prRef: prRef,
                    agentOverride: agentOverride,
                    modelOverride: modelOverride
                )
                sem.signal()
                exit(0)
            } catch {
                fputs("[E2E] FAILED: \(error.localizedDescription)\n", stderr)
                sem.signal()
                exit(1)
            }
        }
        sem.wait()
        exit(0)
    }

    private static func execute(
        prRef: String,
        agentOverride: String?,
        modelOverride: String?
    ) async throws {
        print("[E2E] 1/5 Probing local environment...")
        let detector = EnvironmentDetector()
        let env = await detector.detectAll()
        print("[E2E]   git=\(env.git.executablePath ?? "nil"), gh=\(env.gh.executablePath ?? "nil"), user=@\(env.githubAuth.username ?? "nil")")
        print("[E2E]   lody installed=\(env.isEngineReady(.lody)), exec=\(env.engines[.lody]?.executablePath ?? "nil")")

        print("[E2E] 2/5 Fetching Lody catalog (workspaces, agents, models, local projects, linked repos)...")
        let lodyCatalog: LodyCatalogSnapshot?
        if let lodyProbe = env.engines[.lody], lodyProbe.isInstalled {
            lodyCatalog = await detector.fetchLodyCatalog(lodyProbe: lodyProbe, resolvedPATH: env.resolvedPATH)
        } else {
            lodyCatalog = nil
        }
        print("[E2E]   lody workspace=\(lodyCatalog?.workspaceID ?? "nil"), agents=\(lodyCatalog?.agentConfigs.count ?? 0), models=\(lodyCatalog?.totalModelCount ?? 0), localProjects=\(lodyCatalog?.localProjects.count ?? 0), linkedRepos=\(lodyCatalog?.linkedGitHubRepos.count ?? 0)")

        print("[E2E] 3/5 Fetching real GitHub PR: \(prRef)...")
        let ghConnector = GitHubConnector(
            tokenProvider: DefaultGitHubTokenProvider(detector: detector, ghExecutablePath: env.gh.executablePath)
        )
        let item = try await ghConnector.fetchPullRequest(reference: prRef)
        guard case .codeChange(let code) = item.payload else {
            throw NSError(domain: "E2E", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected codeChange payload"])
        }
        print("[E2E]   PR: \(item.displayContextTag) — \(item.title)")
        print("[E2E]   branch: \(code.headRef) -> \(code.baseRef), sha=\(code.headSHA.prefix(8)), +\(code.additions)/-\(code.deletions) (\(code.changedFiles) files), draft=\(code.isDraft)")

        let agentSelector = agentOverride ?? lodyCatalog?.matchAgentConfig(selector: "antigravity")?.id ?? "default"
        let lodyConfig = LodyConfig(
            workspace: "",
            defaultAgentConfig: agentSelector,
            preferNPXFallback: true,
            useLodyWorktree: true
        )
        let plan = ExecutionPlan(
            engine: .lody,
            model: modelOverride ?? "default",
            lodyAgentConfig: lodyConfig.defaultAgentConfig,
            effort: .medium,
            presetID: "code-review-general",
            launchMode: .nativeBackgroundSession
        )

        print("[E2E] 4/5 Preparing Lody workspace routing...")
        let worktreeManager = WorktreeManager()
        let backend = LodyBackend(config: lodyConfig, catalog: lodyCatalog, worktreeManager: worktreeManager)
        let prepared = try await backend.prepareWorkspace(
            for: WorkspacePreparationRequest(
                item: item,
                plan: plan,
                searchRoots: ["~/work", "~/projects"],
                environment: env
            )
        ) { progress in
            print("[E2E][prepare] \(progress)")
        }
        print("[E2E]   Workspace ready: \(prepared.workspaceURL.path)")

        print("[E2E] 5/5 Dispatching Lody session (agent=\(agentSelector), model=\(plan.model))...")
        let result = try await backend.execute(
            AgentRunRequest(
                item: item,
                plan: plan,
                preset: TaskPreset.defaults[0],
                workspace: prepared,
                environment: env,
                injectPresetPrompt: true
            )
        ) { progress in
            print("[E2E][progress] \(progress)")
        }

        print("[E2E]   wasBackgroundDispatched=\(result.wasBackgroundDispatched)")
        print("[E2E]   sessionID=\(result.sessionHandle?.sessionID ?? "nil")")
        if let handle = result.sessionHandle {
            print("[E2E]   handoff=\(backend.resumeShellCommand(for: handle))")
        }

        if prepared.isTemporaryWorktree, let baseRepo = prepared.baseRepositoryURL {
            let gitPath = env.git.executablePath ?? "/usr/bin/git"
            var gitEnv = ProcessInfo.processInfo.environment
            gitEnv["PATH"] = env.resolvedPATH
            await worktreeManager.removeWorktree(
                baseRepositoryURL: baseRepo,
                worktreeURL: prepared.workspaceURL,
                gitExecutablePath: gitPath,
                environment: gitEnv
            )
            print("[E2E]   Cleaned up temporary worktree.")
        }

        print("[E2E] SUCCESS!")
    }
}
#endif
