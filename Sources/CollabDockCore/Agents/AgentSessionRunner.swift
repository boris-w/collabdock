import Foundation

public struct AgentRunResult: Sendable {
    public let output: ExecutionOutput?
    public let sessionHandle: AgentSessionHandle?
    public let rawOutputText: String
    public let wasBackgroundDispatched: Bool
    public let usage: AgentUsageMetrics?
    public let durationSeconds: Double

    public init(
        output: ExecutionOutput?,
        sessionHandle: AgentSessionHandle?,
        rawOutputText: String,
        wasBackgroundDispatched: Bool = false,
        usage: AgentUsageMetrics? = nil,
        durationSeconds: Double = 0
    ) {
        self.output = output
        self.sessionHandle = sessionHandle
        self.rawOutputText = rawOutputText
        self.wasBackgroundDispatched = wasBackgroundDispatched
        self.usage = usage
        self.durationSeconds = durationSeconds
    }
}

public enum AgentRunnerError: Error, LocalizedError {
    case executableNotFound(String)
    case processFailed(exitCode: Int32, stderr: String)
    case cancelled
    case unparseableOutput(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            if name == "lody" {
                return CoreL10n.string("lody CLI or npx not found. Install Node.js (with npx) or global lody CLI and retry.")
            }
            return CoreL10n.format("Executable not found: %@. Check installation status in Settings → Lody.", name)
        case .processFailed(let code, let stderr):
            let brief = String(stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
            return CoreL10n.format("AI process exited with error (code %lld): %@", Int(code), brief)
        case .cancelled:
            return CoreL10n.string("Review cancelled by user")
        case .unparseableOutput(let sample):
            return CoreL10n.format("Could not parse structured output (raw text kept): %@", String(sample.prefix(160)))
        }
    }
}

/// 线程安全的可取消进程控制器（用于菜单栏实时「中止」正在运行的 AI 进程组）
public final class ProcessCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelledFlag = false

    public init() {}

    public func bind(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        if isCancelledFlag, process.isRunning {
            killProcessGroup(process)
        }
    }

    public func cancel() {
        lock.lock()
        isCancelledFlag = true
        let active = process
        lock.unlock()
        if let active, active.isRunning {
            killProcessGroup(active)
        }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelledFlag
    }

    private func killProcessGroup(_ process: Process) {
        let pid = process.processIdentifier
        if pid > 0 {
            // 向子进程发送终止信号
            kill(pid, SIGTERM)
        }
        process.terminate()
    }
}

/// Lody 子进程流式调度执行器（强制剥离 GitHub 写 Token 与宿主会话变量、支持安全中止，关联 REQ-007, REQ-008, REQ-014）
public struct AgentSessionRunner: Sendable {
    public let lodyBackend: any ExecutionBackend

    public init(
        lodyBackend: any ExecutionBackend = LodyBackend()
    ) {
        self.lodyBackend = lodyBackend
    }

    /// 接受后端无关的 `AgentRunRequest` 并通过 Lody 后端执行
    public func run(
        _ request: AgentRunRequest,
        backend: (any ExecutionBackend)? = nil,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> AgentRunResult {
        let chosen = backend ?? lodyBackend
        return try await chosen.execute(request, onProgress: onProgress)
    }

    public func run(
        item: CollaborationItem,
        plan: ExecutionPlan,
        preset: TaskPreset,
        workspaceURL: URL,
        environmentSnapshot: EnvironmentSnapshot?,
        lodyConfig: LodyConfig,
        lodyCatalog: LodyCatalogSnapshot? = nil,
        lodyWorkspaceTarget: LodyWorkspaceTarget? = nil,
        cancellationToken: ProcessCancellationToken,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> AgentRunResult {
        let workspace = PreparedWorkspaceContext(workspaceURL: workspaceURL)
        let request = AgentRunRequest(
            item: item,
            plan: plan,
            preset: preset,
            workspace: workspace,
            environment: environmentSnapshot,
            cancellationToken: cancellationToken
        )
        let backend = LodyBackend(
            config: lodyConfig,
            catalog: lodyCatalog,
            workspaceTargetOverride: lodyWorkspaceTarget
        )
        return try await backend.execute(request, onProgress: onProgress)
    }

    // MARK: - Shared Subprocess Streaming & Environment Sanitization

    static func sanitizedEnvironment(from environmentSnapshot: EnvironmentSnapshot?) -> [String: String] {
        // 安全防线（REQ-008）：剥离 GitHub 写凭据与宿主会话环境变量，杜绝越权与会话串扰
        var sanitizedEnv = ProcessInfo.processInfo.environment
        if let resolvedPATH = environmentSnapshot?.resolvedPATH {
            sanitizedEnv["PATH"] = resolvedPATH
        }
        for key in [
            "GITHUB_TOKEN", "GH_TOKEN", "GH_ENTERPRISE_TOKEN",
            "ELECTRON_RUN_AS_NODE", "LODY_ELECTRON_BOOTSTRAP",
            "LODY_SESSION_ID", "LODY_WORKSPACE_SESSION_ID", "LODY_AGENT_SESSION_ID"
        ] {
            sanitizedEnv.removeValue(forKey: key)
        }
        return sanitizedEnv
    }

    struct StreamExecResult: Sendable {
        let exitCode: Int32
        let sessionID: String?
        let finalText: String?
        let usage: AgentUsageMetrics?
        let stdout: String
        let stderr: String
    }

    static func executeStreaming(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        cancellationToken: ProcessCancellationToken,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> StreamExecResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.environment = environment

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                cancellationToken.bind(process)

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                final class Accumulator: @unchecked Sendable {
                    let lock = NSLock()
                    var sessionID: String?
                    var finalText: String?
                    var finalUsage: AgentUsageMetrics?
                    var latestStepUsage: AgentUsageMetrics?
                    var stdoutLines: [String] = []
                    var stderrData = Data()
                }
                let acc = Accumulator()
                let group = DispatchGroup()

                // 异步消费 stderr
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    acc.stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                // 逐行流式消费 stdout
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let handle = stdoutPipe.fileHandleForReading
                    var buffer = Data()
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        buffer.append(chunk)
                        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer[..<newlineIndex]
                            buffer.removeSubrange(...newlineIndex)
                            if let line = String(data: lineData, encoding: .utf8) {
                                let parsed = AgentStreamParser.parseLine(line)
                                acc.lock.lock()
                                acc.stdoutLines.append(line)
                                if let sid = parsed.sessionID, acc.sessionID == nil {
                                    acc.sessionID = sid
                                }
                                if let final = parsed.finalText {
                                    acc.finalText = final
                                }
                                if let u = parsed.usage {
                                    if parsed.isFinalUsage {
                                        acc.finalUsage = u
                                    } else {
                                        acc.latestStepUsage = u
                                    }
                                }
                                acc.lock.unlock()
                                if let hint = parsed.progressHint {
                                    onProgress(hint)
                                }
                            }
                        }
                    }
                    if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8) {
                        let parsed = AgentStreamParser.parseLine(tail)
                        acc.lock.lock()
                        acc.stdoutLines.append(tail)
                        if let sid = parsed.sessionID, acc.sessionID == nil {
                            acc.sessionID = sid
                        }
                        if let final = parsed.finalText {
                            acc.finalText = final
                        }
                        if let u = parsed.usage {
                            if parsed.isFinalUsage {
                                acc.finalUsage = u
                            } else {
                                acc.latestStepUsage = u
                            }
                        }
                        acc.lock.unlock()
                    }
                    group.leave()
                }

                process.waitUntilExit()
                group.wait()

                let stderr = String(data: acc.stderrData, encoding: .utf8) ?? ""
                let result = StreamExecResult(
                    exitCode: process.terminationStatus,
                    sessionID: acc.sessionID,
                    finalText: acc.finalText,
                    usage: acc.finalUsage ?? acc.latestStepUsage,
                    stdout: acc.stdoutLines.joined(separator: "\n"),
                    stderr: stderr
                )
                continuation.resume(returning: result)
            }
        }
    }

    public struct ResolvedExecutionBinary: Equatable, Sendable {
        public let executablePath: String?
        public let usesNPXFallback: Bool

        public init(executablePath: String?, usesNPXFallback: Bool) {
            self.executablePath = executablePath
            self.usesNPXFallback = usesNPXFallback
        }
    }

    /// 面向 Lody 侧边栏优化的精简会话标题：归属到项目下时去掉冗余前缀，一眼看到 `CR #编号 标题`
    public static func formatLodySessionTitle(
        item: CollaborationItem,
        hasDedicatedProject: Bool
    ) -> String {
        let cleanTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = item.externalRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = (item.itemKind == .pullRequest) ? "CR" : item.itemKind.shortLabel
        if hasDedicatedProject {
            return ref.isEmpty ? "\(prefix) \(cleanTitle)" : "\(prefix) \(ref) \(cleanTitle)"
        }
        let shortScope = item.scope.split(separator: "/").last.map(String.init) ?? item.scope
        if ref.isEmpty {
            return "\(prefix) \(shortScope) \(cleanTitle)"
        }
        return "\(prefix) \(shortScope) \(ref) \(cleanTitle)"
    }

    /// 统一解析 Lody 可执行路径（优先全局 `lody`，缺失时自动无感回退 `npx -y lody`，不受冷启动环境未就绪影响）
    public static func resolveExecutionBinary(
        engine: AgentEngine = .lody,
        probedPath: String?,
        resolvedPATH: String?,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> ResolvedExecutionBinary {
        if let probedPath,
           !probedPath.hasSuffix("/npx"),
           !probedPath.hasSuffix(".app"),
           fileExists(probedPath) {
            return ResolvedExecutionBinary(executablePath: probedPath, usesNPXFallback: false)
        }
        if let directLody = findInPATH("lody", path: resolvedPATH, fileExists: fileExists) {
            return ResolvedExecutionBinary(executablePath: directLody, usesNPXFallback: false)
        }
        if let probedPath,
           probedPath.hasSuffix("/npx"),
           fileExists(probedPath) {
            return ResolvedExecutionBinary(executablePath: probedPath, usesNPXFallback: true)
        }
        if let npxPath = findInPATH("npx", path: resolvedPATH, fileExists: fileExists) {
            return ResolvedExecutionBinary(executablePath: npxPath, usesNPXFallback: true)
        }
        return ResolvedExecutionBinary(executablePath: nil, usesNPXFallback: false)
    }

    /// 从非零退出的 CLI stdout / stderr 中提取真实错误信息（兼容 `--json` 将 `{"ok":false,"error":"..."}` 输出到 stdout 且 stderr 为空的场景）
    public static func extractFailureMessage(
        stderr: String,
        stdout: String,
        engine: AgentEngine = .lody
    ) -> String {
        let jsonErr = extractJSONErrorString(from: stdout) ?? extractJSONErrorString(from: stderr)
        let rawDetail: String
        if let jsonErr, !jsonErr.isEmpty {
            rawDetail = jsonErr
        } else {
            let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedStderr.isEmpty {
                rawDetail = trimmedStderr
            } else {
                let tailLines = stdout
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .suffix(3)
                    .joined(separator: " ")
                rawDetail = tailLines.isEmpty ? CoreL10n.string("Subprocess produced no error output") : tailLines
            }
        }

        let lower = rawDetail.lowercased()
        if lower.contains("token is invalid")
            || lower.contains("token expired")
            || lower.contains("lody login")
            || lower.contains("not logged in")
            || lower.contains("unauthorized") {
            return CoreL10n.format("Lody CLI login expired. Run `npx -y lody@latest login` in Terminal, then click Retry. (%@)", rawDetail)
        }
        if lower.contains("local project branch not found") {
            return CoreL10n.format("Target branch ref not found in the local project. Check `git fetch` or switch to \"Project Directory\" and retry. (%@)", rawDetail)
        }
        return rawDetail
    }

    private static func extractJSONErrorString(from text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline).reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("{"), line.hasSuffix("}"),
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            if let err = obj["error"] as? String, !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return err.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let errObj = obj["error"] as? [String: Any],
               let msg = errObj["message"] as? String, !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return msg.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let ok = obj["ok"] as? Bool, ok == false,
               let msg = obj["message"] as? String, !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return msg.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let res = obj["result"] as? [String: Any],
               let err = (res["error"] as? String) ?? (res["message"] as? String),
               !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return err.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func findInPATH(
        _ name: String,
        path: String?,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaultPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:\(home)/.local/bin:\(home)/.npm-global/bin:\(home)/.cargo/bin:/usr/bin:/bin"
        let searchPath = (path?.isEmpty == false) ? path! : defaultPath
        for dir in searchPath.split(separator: ":") {
            let full = "\(dir)/\(name)"
            if fileExists(full) {
                return full
            }
        }
        return nil
    }
}
