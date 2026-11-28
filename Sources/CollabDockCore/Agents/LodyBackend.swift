import Foundation

/// Lody 编排层执行后端：封装 Lody 工作区路由、中性临时 cwd、npx -y lody@latest 回退、Deep Link 与标题格式
public struct LodyBackend: ExecutionBackend {
    public let kind: ExecutionBackendKind = .lody

    public let config: LodyConfig
    public let catalog: LodyCatalogSnapshot?
    public let worktreeManager: any WorktreeManaging
    public let commandBuilder: AgentCommandBuilder
    /// 在中性临时目录启动子进程，防止 npx 被目标项目中的本地 package.json 劫持
    public let temporaryWorkingDirectory: URL
    /// 可选显式覆盖的工作区目标（用于兼容旧调用或调用方显式指定）
    public let workspaceTargetOverride: LodyWorkspaceTarget?

    public init(
        config: LodyConfig = LodyConfig(),
        catalog: LodyCatalogSnapshot? = nil,
        worktreeManager: any WorktreeManaging = WorktreeManager(),
        commandBuilder: AgentCommandBuilder = AgentCommandBuilder(),
        temporaryWorkingDirectory: URL = FileManager.default.temporaryDirectory,
        workspaceTargetOverride: LodyWorkspaceTarget? = nil
    ) {
        self.config = config
        self.catalog = catalog
        self.worktreeManager = worktreeManager
        self.commandBuilder = commandBuilder
        self.temporaryWorkingDirectory = temporaryWorkingDirectory
        self.workspaceTargetOverride = workspaceTargetOverride
    }

    public func prepareWorkspace(
        for request: WorkspacePreparationRequest,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> PreparedWorkspaceContext {
        let gitPath = request.environment?.git.executablePath ?? "/usr/bin/git"
        var gitEnv = ProcessInfo.processInfo.environment
        if let path = request.environment?.resolvedPATH {
            gitEnv["PATH"] = path
        }

        let repoName = request.item.payload.linkedRepository
        let prCode: CodeChangePayload? = {
            if case .codeChange(let c) = request.item.payload { return c }
            return nil
        }()

        let resolvedLocalPath: String? = {
            if let explicit = request.preferredLocalPath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !explicit.isEmpty {
                return explicit
            }
            if let repoName {
                let target = repoName.lowercased()
                if let matched = catalog?.localProjects.first(where: {
                    $0.repositoryFullName?.lowercased() == target
                }) {
                    return matched.rootPath
                }
            }
            return nil
        }()

        if let localPath = resolvedLocalPath {
            if let prCode {
                let displayName = URL(fileURLWithPath: localPath).lastPathComponent
                onProgress(CoreL10n.format("Refreshing PR branch refs in local project %@...", displayName))
                await worktreeManager.refreshRemoteRefs(
                    inRepositoryAt: localPath,
                    code: prCode,
                    gitExecutablePath: gitPath,
                    environment: gitEnv
                )
            }
            return PreparedWorkspaceContext(
                workspaceURL: URL(fileURLWithPath: localPath, isDirectory: true),
                baseRepositoryURL: nil,
                isTemporaryWorktree: false
            )
        }

        if let repoName, request.plan.useIsolatedWorktree,
           catalog?.hasLinkedGitHubRepo(repoName) == true {
            return PreparedWorkspaceContext(
                workspaceURL: FileManager.default.homeDirectoryForCurrentUser,
                isTemporaryWorktree: false
            )
        }

        onProgress(
            request.plan.useIsolatedWorktree
                ? CoreL10n.string("Creating isolated read-only Git Worktree...")
                : CoreL10n.string("Preparing project directory context...")
        )
        let extraLocalRepos = catalog?.localProjects.map(\.rootPath) ?? []
        return try await worktreeManager.prepareContext(
            for: request.item,
            searchRoots: request.searchRoots,
            extraLocalRepoPaths: extraLocalRepos,
            preferredLocalPath: request.preferredLocalPath,
            useIsolatedWorktree: request.plan.useIsolatedWorktree,
            gitExecutablePath: gitPath,
            environment: gitEnv
        )
    }

    public func buildCommand(
        for request: AgentRunRequest,
        prompt: String
    ) throws -> AgentCommandSpec {
        let plan = request.plan
        let resolvedBinary = resolveBinary(environment: request.environment)
        let effectiveSelector = (plan.lodyAgentConfig?.isEmpty == false ? plan.lodyAgentConfig! : config.defaultAgentConfig)
        let matchedOption = catalog?.matchAgentConfig(selector: effectiveSelector)
        let target = resolveWorkspaceTarget(for: request.item, plan: plan, workspace: request.workspace)
        let hasDedicatedProject: Bool = {
            switch target {
            case .localProject, .linkedGitHubRepo:
                return true
            case .preparedLocalPath, .none:
                return false
            }
        }()
        let title = formatSessionTitle(for: request.item, hasDedicatedProject: hasDedicatedProject)

        let rawSpec = commandBuilder.buildBackgroundDispatchCommand(
            plan: plan,
            prompt: prompt,
            workspaceURL: request.workspace.workspaceURL,
            lodyConfig: config,
            lodyAgentConfigOption: matchedOption,
            lodyWorkspaceTarget: target,
            sessionTitle: title,
            repositoryFullName: request.item.payload.linkedRepository,
            lodyUseNPXFallback: resolvedBinary.usesNPXFallback,
            executableOverride: resolvedBinary.executablePath
        )

        let finalExecutablePath: String
        if rawSpec.executable.hasPrefix("/") {
            finalExecutablePath = rawSpec.executable
        } else if let found = AgentSessionRunner.findInPATH(rawSpec.executable, path: request.environment?.resolvedPATH) {
            finalExecutablePath = found
        } else {
            throw AgentRunnerError.executableNotFound(rawSpec.executable)
        }

        // Lody CLI 在中性临时目录启动，避免 npx 被目标仓内同名 package.json 劫持
        return AgentCommandSpec(
            executable: finalExecutablePath,
            arguments: rawSpec.arguments,
            workingDirectory: temporaryWorkingDirectory,
            outputFilePath: rawSpec.outputFilePath
        )
    }

    public func execute(
        _ request: AgentRunRequest,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> AgentRunResult {
        let prompt = commandBuilder.buildPrompt(
            item: request.item,
            preset: request.preset,
            extraInstructions: request.plan.extraInstructions,
            previousReview: request.plan.previousReview,
            continuityMode: request.plan.continuityMode
        )

        let spec = try buildCommand(
            for: request,
            prompt: prompt
        )

        let sanitizedEnv = AgentSessionRunner.sanitizedEnvironment(from: request.environment)
        onProgress(CoreL10n.format("Starting %@ (%@)...", AgentEngine.lody.displayName, request.plan.model))

        let startedAt = Date()
        let execResult = try await AgentSessionRunner.executeStreaming(
            executablePath: spec.executable,
            arguments: spec.arguments,
            workingDirectory: spec.workingDirectory,
            environment: sanitizedEnv,
            cancellationToken: request.cancellationToken,
            onProgress: onProgress
        )
        let elapsedSeconds = max(0.1, Date().timeIntervalSince(startedAt))

        if request.cancellationToken.isCancelled {
            throw AgentRunnerError.cancelled
        }

        let raw = RawExecutionOutput(
            exitCode: execResult.exitCode,
            stdout: execResult.stdout,
            stderr: execResult.stderr,
            sessionID: execResult.sessionID,
            finalText: execResult.finalText,
            outputFileText: nil,
            usage: execResult.usage,
            durationSeconds: elapsedSeconds
        )
        return try parseResult(raw, for: request)
    }

    public func parseResult(
        _ raw: RawExecutionOutput,
        for request: AgentRunRequest
    ) throws -> AgentRunResult {
        guard raw.exitCode == 0 else {
            let detail = AgentSessionRunner.extractFailureMessage(
                stderr: raw.stderr,
                stdout: raw.stdout,
                engine: .lody
            )
            throw AgentRunnerError.processFailed(exitCode: raw.exitCode, stderr: detail)
        }

        let sessionHandle = makeSessionHandle(sessionID: raw.sessionID, for: request)
        var finalUsage = raw.usage
        if var u = finalUsage, u.durationSeconds == nil {
            u.durationSeconds = raw.durationSeconds
            finalUsage = u
        }

        return AgentRunResult(
            output: nil,
            sessionHandle: sessionHandle,
            rawOutputText: raw.stdout,
            wasBackgroundDispatched: true,
            usage: finalUsage ?? AgentUsageMetrics(durationSeconds: raw.durationSeconds, metricKind: .pendingSync),
            durationSeconds: raw.durationSeconds
        )
    }

    public func makeSessionHandle(
        sessionID: String?,
        for request: AgentRunRequest
    ) -> AgentSessionHandle? {
        let effectiveSessionID = sessionID
            ?? ((request.plan.continuityMode == .continueSessionIncremental
                 && request.plan.previousReview?.engine == .lody)
                ? request.plan.previousReview?.sessionID
                : nil)
        return effectiveSessionID.map { sid in
            AgentSessionHandle(
                engine: .lody,
                sessionID: sid,
                workspacePath: request.workspace.workspaceURL.path,
                launchMode: request.plan.launchMode
            )
        }
    }

    public func resumeShellCommand(for handle: AgentSessionHandle) -> String {
        if let deepLink = sessionDeepLink(for: handle)?.absoluteString {
            return "open \(Self.shellEscape(deepLink))"
        }
        return "npx lody session list --json"
    }

    // MARK: - Lody 专属能力（绝不泄漏至 DirectCLIBackend 或通用 AgentRunRequest）

    /// 根据 Lody catalog 与准备好的工作区解析 `--local-project` / `--repo` 目标
    public func resolveWorkspaceTarget(
        for item: CollaborationItem,
        plan: ExecutionPlan,
        workspace: PreparedWorkspaceContext
    ) -> LodyWorkspaceTarget? {
        if let override = workspaceTargetOverride {
            return override
        }

        if workspace.isTemporaryWorktree {
            return .preparedLocalPath(workspace.workspaceURL.path)
        }

        let prCode: CodeChangePayload? = {
            if case .codeChange(let c) = item.payload { return c }
            return nil
        }()
        let branch = plan.useIsolatedWorktree ? prCode?.headRef : nil
        let workspacePath = workspace.workspaceURL.standardizedFileURL.path

        if let matchedProject = catalog?.localProjects.first(where: {
            URL(fileURLWithPath: $0.rootPath).standardizedFileURL.path == workspacePath
        }) {
            return .localProject(
                idOrPath: matchedProject.id,
                useWorktree: plan.useIsolatedWorktree,
                branch: branch
            )
        }

        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if workspacePath != homePath {
            return .localProject(
                idOrPath: workspace.workspaceURL.path,
                useWorktree: plan.useIsolatedWorktree,
                branch: branch
            )
        }

        if let repoName = item.payload.linkedRepository,
           plan.useIsolatedWorktree,
           catalog?.hasLinkedGitHubRepo(repoName) == true {
            return .linkedGitHubRepo(fullName: repoName, branch: prCode?.headRef)
        }

        if config.useLodyWorktree,
           let repoName = item.payload.linkedRepository,
           !repoName.isEmpty {
            return .linkedGitHubRepo(fullName: repoName, branch: prCode?.headRef)
        }

        return .preparedLocalPath(workspace.workspaceURL.path)
    }

    /// 解析 Lody 可执行文件（优先全局 `lody`，缺失时自动回退 `npx -y lody@latest`）
    public func resolveBinary(
        environment: EnvironmentSnapshot?,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> AgentSessionRunner.ResolvedExecutionBinary {
        AgentSessionRunner.resolveExecutionBinary(
            engine: .lody,
            probedPath: environment?.engines[.lody]?.executablePath,
            resolvedPATH: environment?.resolvedPATH,
            fileExists: fileExists
        )
    }

    /// 构造官方 Lody Deep Link（支持从 CollabDock 一键在 Lody Desktop 打开对应会话，关联 ADR-007）
    public static func sessionDeepLink(sessionID: String, workspace: String? = nil) -> URL? {
        var comps = URLComponents()
        comps.scheme = "lody"
        comps.host = "session"
        comps.path = "/\(sessionID)"
        if let workspace, !workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            comps.queryItems = [URLQueryItem(name: "workspace", value: workspace)]
        }
        return comps.url
    }

    /// 构造在 Lody Desktop 中打开指定会话的 Deep Link
    public func sessionDeepLink(for handle: AgentSessionHandle) -> URL? {
        Self.sessionDeepLink(
            sessionID: handle.sessionID,
            workspace: effectiveWorkspaceID
        )
    }

    /// 生成面向 Lody 侧边栏优化的精简会话标题
    public func formatSessionTitle(
        for item: CollaborationItem,
        hasDedicatedProject: Bool
    ) -> String {
        AgentSessionRunner.formatLodySessionTitle(
            item: item,
            hasDedicatedProject: hasDedicatedProject
        )
    }

    private var effectiveWorkspaceID: String? {
        let configured = config.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }
        let fromCatalog = catalog?.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fromCatalog.isEmpty ? nil : fromCatalog
    }
}
