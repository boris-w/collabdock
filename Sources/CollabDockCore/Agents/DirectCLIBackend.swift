import Foundation

/// 本机直连 CLI 执行后端（覆盖 Claude Code / Codex / Antigravity，不包含任何 Lody 专属概念）
public struct DirectCLIBackend: ExecutionBackend {
    public let kind: ExecutionBackendKind = .directCLI
    public let supportedEngines: [AgentEngine] = [.claudeCode, .codex, .antigravity]

    public let worktreeManager: any WorktreeManaging
    public let commandBuilder: AgentCommandBuilder

    public init(
        worktreeManager: any WorktreeManaging = WorktreeManager(),
        commandBuilder: AgentCommandBuilder = AgentCommandBuilder()
    ) {
        self.worktreeManager = worktreeManager
        self.commandBuilder = commandBuilder
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
        let prevSHAForIncremental: String? = (request.plan.continuityMode == .freshSessionFull)
            ? nil
            : request.plan.previousReview?.reviewedHeadSHA

        onProgress(
            request.plan.useIsolatedWorktree
                ? CoreL10n.string("Creating isolated read-only Git Worktree...")
                : CoreL10n.string("Preparing project directory context...")
        )
        return try await worktreeManager.prepareContext(
            for: request.item,
            searchRoots: request.searchRoots,
            extraLocalRepoPaths: [],
            preferredLocalPath: request.preferredLocalPath,
            useIsolatedWorktree: request.plan.useIsolatedWorktree,
            previousReviewedSHA: prevSHAForIncremental,
            gitExecutablePath: gitPath,
            environment: gitEnv
        )
    }

    public func buildCommand(
        for request: AgentRunRequest,
        prompt: String,
        schemaFileURL: URL,
        outputFileURL: URL? = nil
    ) throws -> AgentCommandSpec {
        let plan = request.plan
        let isBackgroundDispatch = Self.isBackgroundDispatch(for: plan)
        let probedExec = request.environment?.engines[plan.engine]?.executablePath
        let resolvedBinary = AgentSessionRunner.resolveExecutionBinary(
            engine: plan.engine,
            probedPath: probedExec,
            resolvedPATH: request.environment?.resolvedPATH
        )

        let rawSpec: AgentCommandSpec
        if isBackgroundDispatch {
            rawSpec = commandBuilder.buildBackgroundDispatchCommand(
                plan: plan,
                prompt: prompt,
                workspaceURL: request.workspace.workspaceURL,
                executableOverride: resolvedBinary.executablePath
            )
        } else {
            rawSpec = commandBuilder.buildCommand(
                plan: plan,
                prompt: prompt,
                workspaceURL: request.workspace.workspaceURL,
                schemaFileURL: schemaFileURL,
                codexLastMessageURL: outputFileURL,
                executableOverride: resolvedBinary.executablePath
            )
        }

        let finalExecutablePath: String
        if rawSpec.executable.hasPrefix("/") {
            finalExecutablePath = rawSpec.executable
        } else if let found = AgentSessionRunner.findInPATH(rawSpec.executable, path: request.environment?.resolvedPATH) {
            finalExecutablePath = found
        } else {
            // 纯命令构造不强依赖本机已安装对应 CLI（如 CI 无 codex 二进制时仍可单测 buildCommand）；真正启动前由 execute 校验
            finalExecutablePath = rawSpec.executable
        }

        return AgentCommandSpec(
            executable: finalExecutablePath,
            arguments: rawSpec.arguments,
            workingDirectory: request.workspace.workspaceURL,
            outputFilePath: rawSpec.outputFilePath
        )
    }

    public func execute(
        _ request: AgentRunRequest,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> AgentRunResult {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let schemaURL = tempDir.appendingPathComponent("schema.json")
        try commandBuilder.schema(for: request.item).write(to: schemaURL, atomically: true, encoding: .utf8)
        let codexOutURL = tempDir.appendingPathComponent("codex-last-message.json")

        let isBackgroundDispatch = Self.isBackgroundDispatch(for: request.plan)
        let prompt = commandBuilder.buildSafePrompt(
            item: request.item,
            preset: request.preset,
            extraInstructions: request.plan.extraInstructions,
            launchMode: isBackgroundDispatch ? .nativeBackgroundSession : .managedStructuredRun,
            injectPresetPrompt: request.injectPresetPrompt,
            unifiedDiff: isBackgroundDispatch ? nil : request.workspace.unifiedDiff,
            previousReview: request.plan.previousReview,
            continuityMode: request.plan.continuityMode,
            incrementalDiff: request.workspace.incrementalDiff,
            incrementalCommitLog: request.workspace.incrementalCommitLog,
            wasForcePushed: request.workspace.wasForcePushed
        )

        let spec = try buildCommand(
            for: request,
            prompt: prompt,
            schemaFileURL: schemaURL,
            outputFileURL: codexOutURL
        )
        guard spec.executable.hasPrefix("/") else {
            throw AgentRunnerError.executableNotFound(spec.executable)
        }

        let sanitizedEnv = AgentSessionRunner.sanitizedEnvironment(from: request.environment)
        onProgress(CoreL10n.format("Starting %@ (%@)...", request.plan.engine.displayName, request.plan.model))

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

        let outputFileText: String? = spec.outputFilePath.flatMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return text
        }

        let raw = RawExecutionOutput(
            exitCode: execResult.exitCode,
            stdout: execResult.stdout,
            stderr: execResult.stderr,
            sessionID: execResult.sessionID,
            finalText: execResult.finalText,
            outputFileText: outputFileText,
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
                engine: request.plan.engine
            )
            throw AgentRunnerError.processFailed(exitCode: raw.exitCode, stderr: detail)
        }

        let sessionHandle = makeSessionHandle(sessionID: raw.sessionID, for: request)
        var finalUsage = raw.usage
        if var u = finalUsage, u.durationSeconds == nil {
            u.durationSeconds = raw.durationSeconds
            finalUsage = u
        }

        if Self.isBackgroundDispatch(for: request.plan) {
            return AgentRunResult(
                output: nil,
                sessionHandle: sessionHandle,
                rawOutputText: raw.stdout,
                wasBackgroundDispatched: true,
                usage: finalUsage ?? AgentUsageMetrics(durationSeconds: raw.durationSeconds, metricKind: .pendingSync),
                durationSeconds: raw.durationSeconds
            )
        }

        var candidateText = raw.finalText ?? ""
        if let fileText = raw.outputFileText, !fileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidateText = fileText
        }
        if candidateText.isEmpty {
            candidateText = raw.stdout
        }

        if let parsed = AgentStreamParser.decodeExecutionOutput(from: candidateText, for: request.item) {
            return AgentRunResult(
                output: parsed,
                sessionHandle: sessionHandle,
                rawOutputText: candidateText,
                wasBackgroundDispatched: false,
                usage: finalUsage,
                durationSeconds: raw.durationSeconds
            )
        }

        // 若未严格按 JSON Schema 返回，仍优雅降级为 StructuredReplyResult（绝不把 stream-json init 日志当作正文）
        let trimmedFallback = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFallback.isEmpty, !trimmedFallback.hasPrefix(#"{"event":"init""#) else {
            throw AgentRunnerError.unparseableOutput(
                raw.stderr.isEmpty
                    ? CoreL10n.string("AI returned empty output or was blocked by read-only permissions")
                    : raw.stderr
            )
        }
        let fallbackSummary = String(trimmedFallback.prefix(180))
        return AgentRunResult(
            output: .structuredReply(
                StructuredReplyResult(
                    summary: fallbackSummary,
                    replyMarkdown: trimmedFallback,
                    keyPoints: [],
                    referencedFiles: []
                )
            ),
            sessionHandle: sessionHandle,
            rawOutputText: trimmedFallback,
            wasBackgroundDispatched: false,
            usage: finalUsage,
            durationSeconds: raw.durationSeconds
        )
    }

    public func makeSessionHandle(
        sessionID: String?,
        for request: AgentRunRequest
    ) -> AgentSessionHandle? {
        let effectiveSessionID = sessionID
            ?? ((request.plan.continuityMode == .continueSessionIncremental
                 && request.plan.previousReview?.engine == request.plan.engine)
                ? request.plan.previousReview?.sessionID
                : nil)
        return effectiveSessionID.map { sid in
            AgentSessionHandle(
                engine: request.plan.engine,
                sessionID: sid,
                workspacePath: request.workspace.workspaceURL.path,
                launchMode: request.plan.launchMode
            )
        }
    }

    public func resumeShellCommand(for handle: AgentSessionHandle) -> String {
        let escapedDir = Self.shellEscape(handle.workspacePath)
        let escapedID = Self.shellEscape(handle.sessionID)
        switch handle.engine {
        case .claudeCode:
            if handle.launchMode == .nativeBackgroundSession {
                return "cd \(escapedDir) && claude attach \(escapedID)"
            }
            return "cd \(escapedDir) && claude --resume \(escapedID)"
        case .codex:
            return "cd \(escapedDir) && codex resume \(escapedID)"
        case .antigravity:
            return "cd \(escapedDir) && agy --resume \(escapedID)"
        case .lody:
            return LodyBackend().resumeShellCommand(for: handle)
        }
    }

    private static func isBackgroundDispatch(for plan: ExecutionPlan) -> Bool {
        plan.launchMode == .nativeBackgroundSession && plan.engine == .claudeCode
    }
}
