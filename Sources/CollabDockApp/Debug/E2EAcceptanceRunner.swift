#if DEBUG
import Foundation
import CollabDockCore

/// 仅用于 DEBUG 模式的真实 PR 端到端链路验收器（不编入 Release 包，关联 TASK-014）
public enum E2EAcceptanceRunner {
    public static func runIfRequested() {
        let args = CommandLine.arguments
        guard let prIdx = args.firstIndex(of: "--e2e-pr"), prIdx + 1 < args.count else {
            return
        }
        let prRef = args[prIdx + 1]
        let engineRaw: String = {
            if let idx = args.firstIndex(of: "--engine"), idx + 1 < args.count {
                return args[idx + 1]
            }
            return "lody"
        }()
        let modelOverride: String? = {
            if let idx = args.firstIndex(of: "--model"), idx + 1 < args.count {
                return args[idx + 1]
            }
            return nil
        }()
        let deliveryRaw: String = {
            if let idx = args.firstIndex(of: "--delivery"), idx + 1 < args.count {
                return args[idx + 1]
            }
            return "localDraftOnly"
        }()

        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await execute(
                    prRef: prRef,
                    engineRaw: engineRaw,
                    modelOverride: modelOverride,
                    deliveryRaw: deliveryRaw
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
        engineRaw: String,
        modelOverride: String?,
        deliveryRaw: String
    ) async throws {
        guard let engine = AgentEngine(rawValue: engineRaw) else {
            throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid engine: \(engineRaw)"])
        }
        let deliveryMode = DeliveryMode(rawValue: deliveryRaw) ?? .localDraftOnly

        print("[E2E] 1/5 Probing local environment...")
        let detector = EnvironmentDetector()
        let env = await detector.detectAll()
        print("[E2E]   git=\(env.git.executablePath ?? "nil"), gh=\(env.gh.executablePath ?? "nil"), user=@\(env.githubAuth.username ?? "nil")")
        print("[E2E]   engine(\(engine.rawValue)) installed=\(env.isEngineReady(engine)), exec=\(env.engines[engine]?.executablePath ?? "nil")")

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

        let lodyConfig = LodyConfig(
            workspace: "",
            defaultAgentConfig: lodyCatalog?.matchAgentConfig(selector: "antigravity")?.id ?? "default",
            preferNPXFallback: true,
            useLodyWorktree: true
        )
        let chosenModel: String
        if let modelOverride {
            chosenModel = modelOverride
        } else if engine == .lody {
            chosenModel = "gemini-4-neon"
        } else if engine == .antigravity {
            chosenModel = "gemini-3.8-flash-high"
        } else {
            chosenModel = engine.defaultModels.first?.id ?? "default"
        }

        let plan = ExecutionPlan(
            engine: engine,
            model: chosenModel,
            lodyAgentConfig: engine == .lody ? lodyConfig.defaultAgentConfig : nil,
            effort: .medium,
            presetID: "code-review-general",
            deliveryMode: deliveryMode,
            launchMode: engine == .lody ? .nativeBackgroundSession : .managedStructuredRun
        )

        print("[E2E] 4/5 Preparing isolated workspace / Lody routing...")
        let worktreeManager = WorktreeManager()
        let gitPath = env.git.executablePath ?? "/usr/bin/git"
        var gitEnv = ProcessInfo.processInfo.environment
        gitEnv["PATH"] = env.resolvedPATH
        let extraLocalRepos = lodyCatalog?.localProjects.map(\.rootPath) ?? []

        let prepared: PreparedWorkspaceContext
        var lodyTarget: LodyWorkspaceTarget? = nil

        if engine == .lody {
            if let matchedProject = lodyCatalog?.matchLocalProject(forRepository: code.repository) {
                print("[E2E]   Matched Lody Local Project: \(matchedProject.name) (\(matchedProject.id)) at \(matchedProject.rootPath)")
                await worktreeManager.refreshRemoteRefs(
                    inRepositoryAt: matchedProject.rootPath,
                    code: code,
                    gitExecutablePath: gitPath,
                    environment: gitEnv
                )
                prepared = PreparedWorkspaceContext(workspaceURL: URL(fileURLWithPath: matchedProject.rootPath, isDirectory: true))
                lodyTarget = .localProject(idOrPath: matchedProject.id, useWorktree: true, branch: code.headRef)
            } else if lodyCatalog?.hasLinkedGitHubRepo(code.repository) == true {
                print("[E2E]   Matched Lody Cloud Linked Repo: \(code.repository)")
                prepared = PreparedWorkspaceContext(workspaceURL: FileManager.default.homeDirectoryForCurrentUser)
                lodyTarget = .linkedGitHubRepo(fullName: code.repository, branch: code.headRef)
            } else {
                print("[E2E]   Fallback: creating local isolated worktree for Lody...")
                prepared = try await worktreeManager.prepareContext(
                    for: item,
                    searchRoots: ["~/work", "~/projects"],
                    extraLocalRepoPaths: extraLocalRepos,
                    gitExecutablePath: gitPath,
                    environment: gitEnv
                )
                lodyTarget = .preparedLocalPath(prepared.workspaceURL.path)
            }
        } else {
            prepared = try await worktreeManager.prepareContext(
                for: item,
                searchRoots: ["~/work", "~/projects"],
                extraLocalRepoPaths: extraLocalRepos,
                gitExecutablePath: gitPath,
                environment: gitEnv
            )
            print("[E2E]   Isolated worktree ready: \(prepared.workspaceURL.path)")
            print("[E2E]   Unified diff bytes: \(prepared.unifiedDiff?.utf8.count ?? 0)")
        }

        print("[E2E] 5/5 Executing real AI engine (\(engine.displayName), model=\(plan.model))...")
        let runner = AgentSessionRunner()
        let token = ProcessCancellationToken()
        let result = try await runner.run(
            item: item,
            plan: plan,
            preset: TaskPreset.defaults[0],
            workspaceURL: prepared.workspaceURL,
            environmentSnapshot: env,
            lodyConfig: lodyConfig,
            lodyCatalog: lodyCatalog,
            lodyWorkspaceTarget: lodyTarget,
            unifiedDiff: prepared.unifiedDiff,
            injectPresetPrompt: true,
            cancellationToken: token
        ) { progress in
            print("[E2E][progress] \(progress)")
        }

        print("[E2E]   wasBackgroundDispatched=\(result.wasBackgroundDispatched)")
        print("[E2E]   sessionID=\(result.sessionHandle?.sessionID ?? "nil")")
        if let handle = result.sessionHandle {
            let backend: any ExecutionBackend = (handle.engine == .lody)
                ? LodyBackend(config: LodyConfig(workspace: lodyCatalog?.workspaceID ?? ""))
                : DirectCLIBackend()
            let resumeCmd = backend.resumeShellCommand(for: handle)
            print("[E2E]   handoff=\(resumeCmd)")
        }

        if let output = result.output {
            switch output {
            case .codeReview(let review):
                print("[E2E]   Parsed CodeReviewResult: verdict=\(review.recommendedVerdict.rawValue), comments=\(review.comments.count) (critical=\(review.criticalCount), warning=\(review.warningCount), nit=\(review.nitCount))")
                print("[E2E]   summary=\(review.summary)")
                if let diff = prepared.unifiedDiff {
                    let payload = GitHubReviewFormatter.buildReviewPayload(
                        review: review,
                        commitSHA: code.headSHA,
                        unifiedDiff: diff,
                        mode: .platformDraft
                    )
                    print("[E2E]   DiffLineValidator validated inline comments: \(payload.comments.count)/\(review.comments.count) (event=\(payload.event ?? "nil -> Pending Draft"))")
                }
            case .structuredReply(let reply):
                print("[E2E]   Parsed StructuredReplyResult: summary=\(reply.summary)")
            }

            let receipt = try await ghConnector.deliver(
                output: output,
                for: item,
                mode: deliveryMode,
                plan: plan,
                unifiedDiff: prepared.unifiedDiff
            )
            print("[E2E]   Delivered mode=\(receipt.deliveredMode.rawValue), localReport=\(receipt.localReportPath?.path ?? "nil"), url=\(receipt.destinationURL?.absoluteString ?? "nil")")
        }

        if prepared.isTemporaryWorktree, let baseRepo = prepared.baseRepositoryURL {
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
