import Foundation

public struct ProcessOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

public protocol ProcessRunner: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeoutSeconds: TimeInterval
    ) async -> ProcessOutput
}

/// 安全的非阻塞外部命令执行器（支持超时终止与 stdout/stderr 并发读取，避免管道死锁）
public struct DefaultProcessRunner: ProcessRunner {
    public init() {}

    public func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeoutSeconds: TimeInterval = 5.0
    ) async -> ProcessOutput {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                var cleanEnv = environment
                for key in [
                    "ELECTRON_RUN_AS_NODE", "LODY_ELECTRON_BOOTSTRAP",
                    "LODY_SESSION_ID", "LODY_WORKSPACE_SESSION_ID", "LODY_AGENT_SESSION_ID"
                ] {
                    cleanEnv.removeValue(forKey: key)
                }
                process.environment = cleanEnv
                process.currentDirectoryURL = FileManager.default.temporaryDirectory

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let group = DispatchGroup()
                final class Box: @unchecked Sendable {
                    var outData = Data()
                    var errData = Data()
                }
                let box = Box()

                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        returning: ProcessOutput(exitCode: -1, stdout: "", stderr: error.localizedDescription)
                    )
                    return
                }

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    box.outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    box.errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                let timeoutWork = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + max(0.5, timeoutSeconds),
                    execute: timeoutWork
                )

                process.waitUntilExit()
                timeoutWork.cancel()
                group.wait()

                let stdout = String(data: box.outData, encoding: .utf8) ?? ""
                let stderr = String(data: box.errData, encoding: .utf8) ?? ""
                continuation.resume(
                    returning: ProcessOutput(
                        exitCode: process.terminationStatus,
                        stdout: stdout,
                        stderr: stderr
                    )
                )
            }
        }
    }
}

public struct CLIProbeStatus: Equatable, Codable, Sendable {
    public let name: String
    public let isInstalled: Bool
    public let executablePath: String?
    public let version: String?
    public let errorMessage: String?

    public init(
        name: String,
        isInstalled: Bool,
        executablePath: String? = nil,
        version: String? = nil,
        errorMessage: String? = nil
    ) {
        self.name = name
        self.isInstalled = isInstalled
        self.executablePath = executablePath
        self.version = version
        self.errorMessage = errorMessage
    }
}

public enum GitHubTokenSource: String, Codable, Sendable {
    case ghCLI
    case manualPAT
    case none
}

public struct GitHubAuthSnapshot: Equatable, Codable, Sendable {
    public let isAuthenticated: Bool
    public let username: String?
    /// GitHub 账号展示别名 / 昵称（来自 `gh api user` 的 `name`，如 `Alex`）
    public let displayName: String?
    /// GitHub 头像 URL（来自 `gh api user` 的 `avatar_url`）
    public let avatarURL: String?
    public let tokenSource: GitHubTokenSource
    public let scopes: [String]
    public let hasNotificationsScope: Bool
    public let errorMessage: String?

    public init(
        isAuthenticated: Bool,
        username: String? = nil,
        displayName: String? = nil,
        avatarURL: String? = nil,
        tokenSource: GitHubTokenSource = .none,
        scopes: [String] = [],
        hasNotificationsScope: Bool = false,
        errorMessage: String? = nil
    ) {
        self.isAuthenticated = isAuthenticated
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.tokenSource = tokenSource
        self.scopes = scopes
        self.hasNotificationsScope = hasNotificationsScope
        self.errorMessage = errorMessage
    }
}

public struct EnvironmentSnapshot: Equatable, Codable, Sendable {
    public let resolvedPATH: String
    public let git: CLIProbeStatus
    public let gh: CLIProbeStatus
    public let engines: [AgentEngine: CLIProbeStatus]
    public let githubAuth: GitHubAuthSnapshot
    public let discoveredModels: [AgentEngine: [ModelOption]]
    public let checkedAt: Date

    public init(
        resolvedPATH: String,
        git: CLIProbeStatus,
        gh: CLIProbeStatus,
        engines: [AgentEngine: CLIProbeStatus],
        githubAuth: GitHubAuthSnapshot,
        discoveredModels: [AgentEngine: [ModelOption]],
        checkedAt: Date = Date()
    ) {
        self.resolvedPATH = resolvedPATH
        self.git = git
        self.gh = gh
        self.engines = engines
        self.githubAuth = githubAuth
        self.discoveredModels = discoveredModels
        self.checkedAt = checkedAt
    }

    public func isEngineReady(_ engine: AgentEngine) -> Bool {
        engines[engine]?.isInstalled == true
    }
}

/// 本机运行环境与 CLI 探测器（解决 macOS GUI App PATH 缺失，并动态拉取 agy models，关联 REQ-001, TASK-004）
/// 本机 CLI / GitHub 认证 / Lody 目录环境探测协议（`EnvironmentDetector` 为生产实现，测试可注入 Fake）
public protocol EnvironmentDetecting: Sendable {
    func detectAll(
        customPaths: [String: String],
        manualGitHubPAT: String?
    ) async -> EnvironmentSnapshot
    func resolveGitHubToken(ghExecutablePath: String?, manualPAT: String?) async -> String?
    func fetchLodyCatalog(
        lodyProbe: CLIProbeStatus,
        workspace: String?,
        resolvedPATH: String?
    ) async -> LodyCatalogSnapshot?
    func fetchLodySessionUsage(
        lodyProbe: CLIProbeStatus,
        sessionID: String,
        workspace: String?,
        resolvedPATH: String?
    ) async -> EnvironmentDetector.LodySessionUsageSnapshot?
}

public extension EnvironmentDetecting {
    func detectAll(customPaths: [String: String] = [:]) async -> EnvironmentSnapshot {
        await detectAll(customPaths: customPaths, manualGitHubPAT: nil)
    }
}

public struct EnvironmentDetector: EnvironmentDetecting {
    private let runner: any ProcessRunner

    public init(runner: any ProcessRunner = DefaultProcessRunner()) {
        self.runner = runner
    }

    public func detectAll(
        customPaths: [String: String] = [:],
        manualGitHubPAT: String? = nil
    ) async -> EnvironmentSnapshot {
        let resolvedPATH = await resolveSearchPATH()
        let baseEnv = mergedEnvironment(path: resolvedPATH)

        async let gitProbe = probeBinary(name: "git", versionArgs: ["--version"], override: customPaths["git"], path: resolvedPATH, env: baseEnv)
        async let ghProbe = probeBinary(name: "gh", versionArgs: ["--version"], override: customPaths["gh"], path: resolvedPATH, env: baseEnv)
        async let claudeProbe = probeBinary(name: "claude", versionArgs: ["--version"], override: customPaths["claude"], path: resolvedPATH, env: baseEnv)
        async let codexProbe = probeBinary(name: "codex", versionArgs: ["--version"], override: customPaths["codex"], path: resolvedPATH, env: baseEnv)
        async let agyProbe = probeBinary(name: "agy", versionArgs: ["--version"], override: customPaths["agy"], path: resolvedPATH, env: baseEnv)
        async let lodyProbe = probeLody(override: customPaths["lody"], path: resolvedPATH, env: baseEnv)

        let (git, gh, claude, codex, agy, lody) = await (gitProbe, ghProbe, claudeProbe, codexProbe, agyProbe, lodyProbe)

        let engines: [AgentEngine: CLIProbeStatus] = [
            .claudeCode: claude,
            .codex: codex,
            .antigravity: agy,
            .lody: lody
        ]

        async let ghAuthTask = detectGitHubAuth(ghProbe: gh, env: baseEnv, manualPAT: manualGitHubPAT)
        async let agyModelsTask = fetchAgyModels(agyProbe: agy, env: baseEnv)

        let (ghAuth, agyModels) = await (ghAuthTask, agyModelsTask)

        let discoveredModels: [AgentEngine: [ModelOption]] = [
            .claudeCode: AgentEngine.claudeCode.defaultModels,
            .codex: AgentEngine.codex.defaultModels,
            .antigravity: agyModels.isEmpty ? AgentEngine.antigravity.defaultModels : agyModels,
            .lody: AgentEngine.lody.defaultModels
        ]

        return EnvironmentSnapshot(
            resolvedPATH: resolvedPATH,
            git: git,
            gh: gh,
            engines: engines,
            githubAuth: ghAuth,
            discoveredModels: discoveredModels,
            checkedAt: Date()
        )
    }

    public func resolveGitHubToken(
        ghExecutablePath: String? = nil,
        manualPAT: String? = nil
    ) async -> String? {
        if let pat = manualPAT?.trimmingCharacters(in: .whitespacesAndNewlines), !pat.isEmpty {
            return pat
        }
        let path = await resolveSearchPATH()
        let env = mergedEnvironment(path: path)
        let ghPath = ghExecutablePath ?? findExecutable(named: "gh", in: path)
        guard let ghPath else { return nil }
        let res = await runner.run(
            executablePath: ghPath,
            arguments: ["auth", "token"],
            environment: env,
            timeoutSeconds: 4.0
        )
        guard res.succeeded else { return nil }
        let token = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    public func resolveSearchPATH() async -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let baseline = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.cargo/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var entries = currentPath.split(separator: ":").map(String.init)

        // 若从 Finder 启动的 GUI .app 缺少用户 PATH，用登录 Shell 补全（限时 2 秒）
        if !entries.contains("/opt/homebrew/bin") && FileManager.default.isExecutableFile(atPath: "/bin/zsh") {
            let shellRes = await runner.run(
                executablePath: "/bin/zsh",
                arguments: ["-lc", "printf '%s' \"$PATH\""],
                environment: ProcessInfo.processInfo.environment,
                timeoutSeconds: 2.0
            )
            if shellRes.succeeded {
                let shellEntries = shellRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: ":")
                    .map(String.init)
                entries.append(contentsOf: shellEntries)
            }
        }

        entries.append(contentsOf: baseline)
        return Self.deduplicatePATH(entries)
    }

    public static func deduplicatePATH(_ entries: [String]) -> String {
        var seen: Set<String> = []
        var unique: [String] = []
        for entry in entries {
            let cleaned = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            unique.append(cleaned)
        }
        return unique.joined(separator: ":")
    }

    public static func parseAgyModelsOutput(_ output: String) -> [ModelOption] {
        var options: [ModelOption] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.lowercased().hasPrefix("fetching ") || line.lowercased().hasPrefix("available ") {
                continue
            }
            let parts = line.split(separator: "\t", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                options.append(ModelOption(id: parts[0], displayName: parts[1]))
            }
        }
        return options
    }

    public static func parseGHAuthStatus(_ combinedOutput: String) -> (username: String?, scopes: [String]) {
        var username: String?
        var scopes: [String] = []

        if let match = firstCapture(pattern: #"Logged in to [^\s]+ account ([A-Za-z0-9\-_]+)"#, in: combinedOutput) {
            username = match
        }
        if let scopeLine = firstCapture(pattern: #"Token scopes:\s*(.+)"#, in: combinedOutput) {
            scopes = scopeLine
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"`")) }
                .filter { !$0.isEmpty }
        }
        return (username, scopes)
    }

    public static func parseFirstVersionLine(_ output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    // MARK: - Lody.ai 实时目录解析与探测（关联 REQ-014, ADR-007, ITER-009）

    /// 从 `lody workspace list --json` 输出中提取工作区列表（兼容前导日志行）
    public static func parseLodyWorkspacesOutput(_ output: String) -> [LodyWorkspaceOption] {
        guard let root = extractLastJSONObject(from: output),
              let rawWorkspaces = root["workspaces"] as? [[String: Any]] else {
            return []
        }
        return rawWorkspaces.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let slug = (item["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return LodyWorkspaceOption(
                id: id,
                name: (name?.isEmpty == false) ? name! : id,
                slug: (slug?.isEmpty == false) ? slug : nil
            )
        }
    }

    /// 从 `lody agent-config list --json` 输出中提取 Agent Config 及其支持的真实模型、思考强度键与只读模式
    public static func parseLodyAgentConfigsOutput(_ output: String) -> LodyCatalogSnapshot? {
        guard let root = extractLastJSONObject(from: output),
              let rawItems = root["items"] as? [[String: Any]] else {
            return nil
        }
        let workspaceID = root["workspaceId"] as? String

        let configs: [LodyAgentConfigOption] = rawItems.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
            let agentType = item["agentType"] as? String
            let availability = (item["availability"] as? [String: Any])?["state"] as? String

            let runConfig = item["runConfig"] as? [String: Any]
            let configOptions = runConfig?["configOptions"] as? [[String: Any]] ?? []

            var models: [ModelOption] = []
            if let rawModels = runConfig?["models"] as? [[String: Any]], !rawModels.isEmpty {
                models = rawModels.compactMap { m in
                    guard let mid = m["id"] as? String, !mid.isEmpty else { return nil }
                    let mname = (m["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return ModelOption(id: mid, displayName: (mname?.isEmpty == false) ? mname! : mid)
                }
            } else if let modelOpt = configOptions.first(where: { ($0["category"] as? String) == "model" }),
                      let opts = modelOpt["options"] as? [[String: Any]] {
                models = opts.compactMap { o in
                    guard let val = o["value"] as? String, !val.isEmpty else { return nil }
                    let label = (o["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return ModelOption(id: val, displayName: (label?.isEmpty == false) ? label! : val)
                }
            }

            let thoughtOpt = configOptions.first(where: { ($0["category"] as? String) == "thought_level" })
            let effortOptionKey = thoughtOpt?["id"] as? String

            var effortValues = runConfig?["reasoningEffortValues"] as? [String] ?? []
            if effortValues.isEmpty, let opts = thoughtOpt?["options"] as? [[String: Any]] {
                effortValues = opts.compactMap { $0["value"] as? String }
            }

            let rawModes = runConfig?["modes"] as? [[String: Any]] ?? []
            var parsedModes: [AgentModeOption] = rawModes.compactMap { m in
                guard let mid = m["id"] as? String, !mid.isEmpty else { return nil }
                let mname = (m["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let mdesc = (m["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return AgentModeOption(
                    id: mid,
                    displayName: (mname?.isEmpty == false) ? mname! : mid,
                    description: (mdesc?.isEmpty == false) ? mdesc : nil
                )
            }
            if parsedModes.isEmpty,
               let modeOpt = configOptions.first(where: { ($0["category"] as? String) == "mode" }),
               let opts = modeOpt["options"] as? [[String: Any]] {
                parsedModes = opts.compactMap { o in
                    guard let val = o["value"] as? String, !val.isEmpty else { return nil }
                    let label = (o["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let desc = (o["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return AgentModeOption(
                        id: val,
                        displayName: (label?.isEmpty == false) ? label! : val,
                        description: (desc?.isEmpty == false) ? desc : nil
                    )
                }
            }
            let modeIDs = parsedModes.map(\.id)
            let readOnlyModeID: String?
            if modeIDs.contains("read-only") {
                readOnlyModeID = "read-only"
            } else if modeIDs.contains("plan") {
                readOnlyModeID = "plan"
            } else {
                readOnlyModeID = nil
            }

            return LodyAgentConfigOption(
                id: id,
                name: name,
                agentType: agentType,
                models: models,
                modes: parsedModes,
                effortOptionKey: effortOptionKey,
                reasoningEffortValues: effortValues,
                readOnlyModeID: readOnlyModeID,
                availabilityState: availability
            )
        }

        return LodyCatalogSnapshot(
            workspaceID: workspaceID,
            workspaces: [],
            agentConfigs: configs,
            fetchedAt: Date()
        )
    }

    /// 从 `lody project list --json` 输出中提取本地项目，并读取 `.git/config` 关联 `owner/repo`
    public static func parseLodyLocalProjectsOutput(_ output: String) -> [LodyLocalProjectOption] {
        guard let root = extractJSONObject(from: output) else { return [] }
        var rawProjects: [[String: Any]] = []
        if let result = root["result"] as? [String: Any],
           let workspaces = result["workspaces"] as? [[String: Any]] {
            for ws in workspaces {
                if let projects = ws["projects"] as? [[String: Any]] {
                    rawProjects.append(contentsOf: projects)
                }
            }
        } else if let direct = root["projects"] as? [[String: Any]] {
            rawProjects = direct
        } else if let items = root["items"] as? [[String: Any]] {
            rawProjects = items
        }

        var seen: Set<String> = []
        return rawProjects.compactMap { p in
            let id = (p["localProjectId"] as? String) ?? (p["id"] as? String) ?? ""
            guard !id.isEmpty, !seen.contains(id) else { return nil }
            seen.insert(id)
            let name = (p["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id
            let rootPath = (p["rootPath"] as? String) ?? (p["path"] as? String) ?? ""
            guard !rootPath.isEmpty else { return nil }
            let repoFullName = inferGitHubRepoFullName(atLocalPath: rootPath)
            return LodyLocalProjectOption(
                id: id,
                name: name,
                rootPath: rootPath,
                repositoryFullName: repoFullName
            )
        }
    }

    /// 从 `lody github list --json` 输出中提取工作区云端已绑定的 GitHub 仓库列表
    public static func parseLodyLinkedReposOutput(_ output: String) -> [String] {
        guard let root = extractJSONObject(from: output) else { return [] }
        let rawRepos = (root["repositories"] as? [[String: Any]])
            ?? (root["items"] as? [[String: Any]])
            ?? []
        return rawRepos.compactMap { item in
            if let full = item["fullName"] as? String, !full.isEmpty { return full }
            if let full = item["full_name"] as? String, !full.isEmpty { return full }
            if let owner = item["owner"] as? String, let name = item["name"] as? String {
                return "\(owner)/\(name)"
            }
            return nil
        }
    }

    /// 通过本机 `lody` 或 `npx -y lody` 实时拉取用户的 Lody 工作区、Agent Config、本地项目与云端绑定仓库
    public func fetchLodyCatalog(
        lodyProbe: CLIProbeStatus,
        workspace: String? = nil,
        resolvedPATH: String? = nil
    ) async -> LodyCatalogSnapshot? {
        guard lodyProbe.isInstalled, let execPath = lodyProbe.executablePath else {
            return nil
        }
        if execPath.hasSuffix(".app") {
            return nil
        }

        let path: String
        if let resolvedPATH, !resolvedPATH.isEmpty {
            path = resolvedPATH
        } else {
            path = await resolveSearchPATH()
        }
        let env = mergedEnvironment(path: path)
        let isNPX = execPath.hasSuffix("/npx")
        let basePrefix: [String] = isNPX ? ["-y", "lody@latest"] : []
        let wsArg: [String] = {
            if let ws = workspace?.trimmingCharacters(in: .whitespacesAndNewlines), !ws.isEmpty {
                return ["--workspace", ws]
            }
            return []
        }()

        async let agentOut = runner.run(
            executablePath: execPath,
            arguments: basePrefix + ["agent-config", "list", "--json"] + wsArg,
            environment: env,
            timeoutSeconds: 15.0
        )
        async let wsOut = runner.run(
            executablePath: execPath,
            arguments: basePrefix + ["workspace", "list", "--json"],
            environment: env,
            timeoutSeconds: 12.0
        )
        async let projOut = runner.run(
            executablePath: execPath,
            arguments: basePrefix + ["project", "list", "--json"],
            environment: env,
            timeoutSeconds: 12.0
        )
        async let ghRepoOut = runner.run(
            executablePath: execPath,
            arguments: basePrefix + ["github", "list", "--json"] + wsArg,
            environment: env,
            timeoutSeconds: 12.0
        )

        let (agentRes, wsRes, projRes, ghRepoRes) = await (agentOut, wsOut, projOut, ghRepoOut)
        let parsedAgents = Self.parseLodyAgentConfigsOutput(agentRes.stdout)
        let parsedWorkspaces = Self.parseLodyWorkspacesOutput(wsRes.stdout)
        let parsedProjects = Self.parseLodyLocalProjectsOutput(projRes.stdout)
        let parsedLinkedRepos = Self.parseLodyLinkedReposOutput(ghRepoRes.stdout)

        if parsedAgents == nil && parsedWorkspaces.isEmpty && parsedProjects.isEmpty {
            return nil
        }

        return LodyCatalogSnapshot(
            workspaceID: parsedAgents?.workspaceID ?? parsedWorkspaces.first?.id,
            workspaces: parsedWorkspaces,
            agentConfigs: parsedAgents?.agentConfigs ?? [],
            localProjects: parsedProjects,
            linkedGitHubRepos: parsedLinkedRepos,
            fetchedAt: Date()
        )
    }

    /// Lody 异步会话实时状态与用量快照（通过 `lody session show <id> --json` 回拉，关联 ITER-014, ITER-015）
    public struct LodySessionUsageSnapshot: Equatable, Sendable {
        public let sessionID: String
        public let statusType: String
        public let isSettledIdle: Bool
        public let contextUsedTokens: Int
        public let modelID: String?
        public let modelName: String?
        public let lastMessageAt: Date?
        public let durationSeconds: Double?

        public var isRunning: Bool {
            statusType == "running" || statusType == "initializing" || statusType == "queued" || statusType == "starting"
        }

        public var isError: Bool {
            statusType == "error" || statusType == "failed"
        }

        public init(
            sessionID: String,
            statusType: String = "idle",
            isSettledIdle: Bool,
            contextUsedTokens: Int,
            modelID: String? = nil,
            modelName: String? = nil,
            lastMessageAt: Date? = nil,
            durationSeconds: Double? = nil
        ) {
            self.sessionID = sessionID
            self.statusType = statusType
            self.isSettledIdle = isSettledIdle
            self.contextUsedTokens = contextUsedTokens
            self.modelID = modelID
            self.modelName = modelName
            self.lastMessageAt = lastMessageAt
            self.durationSeconds = durationSeconds
        }

        /// 按本轮派发时间计算耗时（最后一条消息时间 − 本轮派发时间，无 1 小时上限；若尚未产出晚于派发时间的新消息则返回 nil）
        public func roundDurationSeconds(since dispatchedAt: Date) -> Double? {
            guard let lastMessageAt else { return nil }
            let diff = lastMessageAt.timeIntervalSince(dispatchedAt)
            return diff > 0 ? diff : nil
        }
    }

    public static func parseLodySessionShowOutput(_ output: String) -> LodySessionUsageSnapshot? {
        guard let root = extractJSONObject(from: output),
              let session = root["session"] as? [String: Any],
              let sid = session["id"] as? String, !sid.isEmpty else {
            return nil
        }
        let statusType = ((session["status"] as? [String: Any])?["type"] as? String)?.lowercased() ?? ""
        let isIdle = (statusType == "idle" || statusType == "completed" || statusType == "stopped")

        let ctxUsage = session["contextWindowUsage"] as? [String: Any]
        let usedTokens: Int = {
            if let n = ctxUsage?["used"] as? Int { return n }
            if let n = ctxUsage?["used"] as? NSNumber { return n.intValue }
            return 0
        }()

        let lastModel = session["lastModel"] as? [String: Any]
        let modelID = lastModel?["modelId"] as? String
        let modelName = lastModel?["name"] as? String

        let lastMessageAt: Date? = {
            if let lastMs = (session["lastMessageAt"] as? NSNumber)?.doubleValue, lastMs > 0 {
                return Date(timeIntervalSince1970: lastMs / 1000.0)
            }
            if let lastStr = session["lastMessageAt"] as? String {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fallbackISO = ISO8601DateFormatter()
                return iso.date(from: lastStr) ?? fallbackISO.date(from: lastStr)
            }
            return nil
        }()

        var durationSec: Double?
        if let lastMessageAt, let createdStr = session["createdAt"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallbackISO = ISO8601DateFormatter()
            if let start = iso.date(from: createdStr) ?? fallbackISO.date(from: createdStr) {
                let diff = lastMessageAt.timeIntervalSince(start)
                if diff > 0 {
                    durationSec = diff
                }
            }
        }

        return LodySessionUsageSnapshot(
            sessionID: sid,
            statusType: statusType,
            isSettledIdle: isIdle,
            contextUsedTokens: max(0, usedTokens),
            modelID: modelID,
            modelName: modelName,
            lastMessageAt: lastMessageAt,
            durationSeconds: durationSec
        )
    }

    public func fetchLodySessionUsage(
        lodyProbe: CLIProbeStatus,
        sessionID: String,
        workspace: String? = nil,
        resolvedPATH: String? = nil
    ) async -> LodySessionUsageSnapshot? {
        guard lodyProbe.isInstalled, let execPath = lodyProbe.executablePath, !execPath.hasSuffix(".app") else {
            return nil
        }
        let path: String
        if let resolvedPATH, !resolvedPATH.isEmpty {
            path = resolvedPATH
        } else {
            path = await resolveSearchPATH()
        }
        let env = mergedEnvironment(path: path)
        let isNPX = execPath.hasSuffix("/npx")
        var args: [String] = isNPX ? ["-y", "lody@latest"] : []
        args.append(contentsOf: ["session", "show", sessionID, "--json"])
        if let ws = workspace?.trimmingCharacters(in: .whitespacesAndNewlines), !ws.isEmpty {
            args.append(contentsOf: ["--workspace", ws])
        }
        let res = await runner.run(
            executablePath: execPath,
            arguments: args,
            environment: env,
            timeoutSeconds: 15.0
        )
        guard res.succeeded else { return nil }
        return Self.parseLodySessionShowOutput(res.stdout)
    }

    private static func inferGitHubRepoFullName(atLocalPath rootPath: String) -> String? {
        let configPath = (rootPath as NSString).appendingPathComponent(".git/config")
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8),
              let origin = RepoScanner.extractOriginURL(fromGitConfig: content) else {
            return nil
        }
        return RepoScanner.parseGitHubRepoFullName(fromRemoteURL: origin)
    }

    private static func extractLastJSONObject(from text: String) -> [String: Any]? {
        extractJSONObject(from: text)
    }

    /// 兼容单行 JSON（带前导传输日志行）与多行缩进 JSON（如 `lody project list --json`）
    private static func extractJSONObject(from text: String) -> [String: Any]? {
        let trimmedAll = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAll.hasPrefix("{"),
           let data = trimmedAll.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return obj
        }
        // 优先从后往前找完整单行 JSON
        for rawLine in text.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            return obj
        }
        // 兜底：截取首个 `{` 到最后一个 `}`（处理带前导日志的多行 JSON）
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            let slice = String(text[first...last])
            if let data = slice.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

    private func probeBinary(
        name: String,
        versionArgs: [String],
        override: String?,
        path: String,
        env: [String: String]
    ) async -> CLIProbeStatus {
        let resolved: String?
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            resolved = FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        } else {
            resolved = findExecutable(named: name, in: path)
        }

        guard let execPath = resolved else {
            return CLIProbeStatus(name: name, isInstalled: false, errorMessage: CoreL10n.format("%@ not found in PATH", name))
        }

        let res = await runner.run(
            executablePath: execPath,
            arguments: versionArgs,
            environment: env,
            timeoutSeconds: 3.0
        )
        let version = Self.parseFirstVersionLine(res.stdout.isEmpty ? res.stderr : res.stdout)
        return CLIProbeStatus(
            name: name,
            isInstalled: true,
            executablePath: execPath,
            version: version
        )
    }

    /// 探测 Lody.ai（支持全局 `lody` CLI、`/Applications/Lody.app` 或 `npx lody` 回退，关联 ADR-007）
    private func probeLody(
        override: String?,
        path: String,
        env: [String: String]
    ) async -> CLIProbeStatus {
        let direct = await probeBinary(name: "lody", versionArgs: ["--version"], override: override, path: path, env: env)
        if direct.isInstalled {
            return direct
        }

        let hasDesktopApp = FileManager.default.fileExists(atPath: "/Applications/Lody.app")
            || FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Lody.app").path
            )
        let npxPath = findExecutable(named: "npx", in: path)

        if let npxPath {
            let label = hasDesktopApp ? "Lody.app · via npx lody" : "via npx lody"
            return CLIProbeStatus(
                name: "lody",
                isInstalled: true,
                executablePath: npxPath,
                version: label
            )
        }

        if hasDesktopApp {
            return CLIProbeStatus(
                name: "lody",
                isInstalled: true,
                executablePath: "/Applications/Lody.app",
                version: CoreL10n.string("Lody Desktop (requires Node/npx or lody CLI)")
            )
        }

        return CLIProbeStatus(
            name: "lody",
            isInstalled: false,
            errorMessage: CoreL10n.string("lody CLI or Lody.app not detected (run `npx lody daemon start` to connect)")
        )
    }

    private func detectGitHubAuth(
        ghProbe: CLIProbeStatus,
        env: [String: String],
        manualPAT: String?
    ) async -> GitHubAuthSnapshot {
        if let pat = manualPAT?.trimmingCharacters(in: .whitespacesAndNewlines), !pat.isEmpty {
            return GitHubAuthSnapshot(
                isAuthenticated: true,
                username: nil,
                tokenSource: .manualPAT,
                scopes: [],
                hasNotificationsScope: true
            )
        }
        guard ghProbe.isInstalled, let ghPath = ghProbe.executablePath else {
            return GitHubAuthSnapshot(
                isAuthenticated: false,
                tokenSource: .none,
                errorMessage: CoreL10n.string("gh CLI not detected. Install gh or enter a PAT.")
            )
        }

        let statusRes = await runner.run(
            executablePath: ghPath,
            arguments: ["auth", "status"],
            environment: env,
            timeoutSeconds: 4.0
        )
        let combined = statusRes.stdout + "\n" + statusRes.stderr
        let parsed = Self.parseGHAuthStatus(combined)

        if statusRes.succeeded {
            let hasNotif = parsed.scopes.contains("notifications")
            let profileRes = await runner.run(
                executablePath: ghPath,
                arguments: ["api", "user"],
                environment: env,
                timeoutSeconds: 4.0
            )
            let profile = profileRes.succeeded ? Self.parseGitHubUserProfile(profileRes.stdout) : nil
            let effectiveLogin = profile?.login ?? parsed.username
            let fallbackAvatar = effectiveLogin.map { "https://github.com/\($0).png?size=80" }
            return GitHubAuthSnapshot(
                isAuthenticated: true,
                username: effectiveLogin,
                displayName: profile?.displayName,
                avatarURL: profile?.avatarURL ?? fallbackAvatar,
                tokenSource: .ghCLI,
                scopes: parsed.scopes,
                hasNotificationsScope: hasNotif
            )
        }

        return GitHubAuthSnapshot(
            isAuthenticated: false,
            tokenSource: .none,
            errorMessage: CoreL10n.string("gh is not logged in. Run `gh auth login`.")
        )
    }

    /// 解析 `gh api user` 返回的 JSON，提取登录名、显示别名与头像链接
    public static func parseGitHubUserProfile(_ output: String) -> (login: String?, displayName: String?, avatarURL: String?)? {
        guard let obj = extractJSONObject(from: output) else { return nil }
        let login = (obj["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let avatar = (obj["avatar_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            login: (login?.isEmpty == false) ? login : nil,
            displayName: (rawName?.isEmpty == false) ? rawName : nil,
            avatarURL: (avatar?.isEmpty == false) ? avatar : nil
        )
    }

    private func fetchAgyModels(
        agyProbe: CLIProbeStatus,
        env: [String: String]
    ) async -> [ModelOption] {
        guard agyProbe.isInstalled, let agyPath = agyProbe.executablePath else {
            return []
        }
        let res = await runner.run(
            executablePath: agyPath,
            arguments: ["models"],
            environment: env,
            timeoutSeconds: 6.0
        )
        guard res.succeeded else { return [] }
        return Self.parseAgyModelsOutput(res.stdout)
    }

    private func findExecutable(named name: String, in path: String) -> String? {
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func mergedEnvironment(path: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        return env
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}
