import Foundation

public struct PreparedWorkspaceContext: Equatable, Sendable {
    public let workspaceURL: URL
    public let baseRepositoryURL: URL?
    public let isTemporaryWorktree: Bool
    public let unifiedDiff: String?
    /// 复审场景：相对上次审查 SHA 的增量 Unified Diff（若分支被 force-push 则自动回退为全量 Diff）
    public let incrementalDiff: String?
    /// 复审场景：新增 Commit 列表（`git log --oneline`）
    public let incrementalCommitLog: String?
    /// 复审场景：上次审查的 SHA 是否已不在当前分支历史中（发生了 rebase / force-push）
    public let wasForcePushed: Bool

    public init(
        workspaceURL: URL,
        baseRepositoryURL: URL? = nil,
        isTemporaryWorktree: Bool = false,
        unifiedDiff: String? = nil,
        incrementalDiff: String? = nil,
        incrementalCommitLog: String? = nil,
        wasForcePushed: Bool = false
    ) {
        self.workspaceURL = workspaceURL
        self.baseRepositoryURL = baseRepositoryURL
        self.isTemporaryWorktree = isTemporaryWorktree
        self.unifiedDiff = unifiedDiff
        self.incrementalDiff = incrementalDiff
        self.incrementalCommitLog = incrementalCommitLog
        self.wasForcePushed = wasForcePushed
    }
}

public enum WorkspaceError: Error, LocalizedError {
    case gitUnavailable
    case cloneFailed(String)
    case fetchFailed(String)
    case worktreeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .gitUnavailable:
            return CoreL10n.string("git executable not found")
        case .cloneFailed(let msg):
            return CoreL10n.format("Shallow clone failed: %@", msg)
        case .fetchFailed(let msg):
            return CoreL10n.format("Failed to fetch PR branch: %@", msg)
        case .worktreeFailed(let msg):
            return CoreL10n.format("Failed to create isolated Git Worktree: %@", msg)
        }
    }
}

/// 扫描用户本地代码根目录，建立 `owner/repo -> localPath` 映射（关联 REQ-006, TASK-011）
public struct RepoScanner: Sendable {
    public init() {}

    public func scanRepositories(in searchRoots: [String], maxDepth: Int = 3) -> [String: URL] {
        let fm = FileManager.default
        var mapping: [String: URL] = [:]
        for rawRoot in searchRoots {
            let expanded = (rawRoot as NSString).expandingTildeInPath
            let rootURL = URL(fileURLWithPath: expanded, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            walkDirectory(rootURL, depth: 0, maxDepth: maxDepth, fm: fm, into: &mapping)
        }
        return mapping
    }

    public static func parseGitHubRepoFullName(fromRemoteURL remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // SSH: git@github.com:owner/repo.git
        if let range = trimmed.range(of: "github.com:") {
            let suffix = String(trimmed[range.upperBound...])
            return normalizeOwnerRepo(suffix)
        }

        // HTTPS / ssh://git@github.com/owner/repo.git
        if let range = trimmed.range(of: "github.com/") {
            let suffix = String(trimmed[range.upperBound...])
            return normalizeOwnerRepo(suffix)
        }

        return nil
    }

    private static func normalizeOwnerRepo(_ raw: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if cleaned.hasSuffix(".git") {
            cleaned = String(cleaned.dropLast(4))
        }
        let parts = cleaned.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])".lowercased()
    }

    private func walkDirectory(_ dir: URL, depth: Int, maxDepth: Int, fm: FileManager, into mapping: inout [String: URL]) {
        let gitDir = dir.appendingPathComponent(".git")
        var isGitDir: ObjCBool = false
        if fm.fileExists(atPath: gitDir.path, isDirectory: &isGitDir) {
            if isGitDir.boolValue {
                let configURL = gitDir.appendingPathComponent("config")
                if let content = try? String(contentsOf: configURL, encoding: .utf8),
                   let remote = Self.extractOriginURL(fromGitConfig: content),
                   let fullName = Self.parseGitHubRepoFullName(fromRemoteURL: remote),
                   mapping[fullName] == nil {
                    mapping[fullName] = dir
                }
            }
            // 不再深入已识别仓库的内部子目录
            return
        }

        guard depth < maxDepth else { return }
        guard let children = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let skipNames: Set<String> = ["node_modules", ".build", "DerivedData", "Pods", "vendor", "dist", "build", "target"]
        for child in children {
            if skipNames.contains(child.lastPathComponent) { continue }
            if let values = try? child.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
                walkDirectory(child, depth: depth + 1, maxDepth: maxDepth, fm: fm, into: &mapping)
            }
        }
    }

    public static func extractOriginURL(fromGitConfig config: String) -> String? {
        var inOriginSection = false
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOriginSection = (line == #"[remote "origin"]"#)
                continue
            }
            if inOriginSection, line.hasPrefix("url") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }
}

/// 隔离 Git Worktree 与增量 Diff 准备协议（`WorktreeManager` 为生产实现，供后端与服务单测注入 Fake）
public protocol WorktreeManaging: Sendable {
    func prepareContext(
        for item: CollaborationItem,
        searchRoots: [String],
        extraLocalRepoPaths: [String],
        preferredLocalPath: String?,
        useIsolatedWorktree: Bool,
        previousReviewedSHA: String?,
        gitExecutablePath: String,
        environment: [String: String]
    ) async throws -> PreparedWorkspaceContext

    func refreshRemoteRefs(
        inRepositoryAt rootPath: String,
        code: CodeChangePayload,
        gitExecutablePath: String,
        environment: [String: String]
    ) async

    func computeIncrementalChanges(
        inRepositoryAt rootPath: String,
        previousSHA: String,
        code: CodeChangePayload,
        gitExecutablePath: String,
        environment: [String: String]
    ) async -> (diff: String?, commitLog: String?, wasForcePushed: Bool)
}

/// 上下文与隔离 Git Worktree 管理器（绝不污染用户当前分支与未提交修改，关联 REQ-006, TASK-011）
public struct WorktreeManager: WorktreeManaging {
    private let runner: any ProcessRunner
    private let cacheRootURL: URL

    public init(
        runner: any ProcessRunner = DefaultProcessRunner(),
        cacheRootURL: URL? = nil
    ) {
        self.runner = runner
        if let cacheRootURL {
            self.cacheRootURL = cacheRootURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.cacheRootURL = caches.appendingPathComponent("CollabDock", isDirectory: true)
        }
    }

    public func prepareContext(
        for item: CollaborationItem,
        searchRoots: [String],
        extraLocalRepoPaths: [String] = [],
        preferredLocalPath: String? = nil,
        useIsolatedWorktree: Bool = true,
        previousReviewedSHA: String? = nil,
        gitExecutablePath: String,
        environment: [String: String]
    ) async throws -> PreparedWorkspaceContext {
        let scanner = RepoScanner()
        var localRepos = scanner.scanRepositories(in: searchRoots)
        // 合并来自 Lody 本地项目等已知仓库路径，免去重复浅克隆
        for rawPath in extraLocalRepoPaths {
            let expanded = (rawPath as NSString).expandingTildeInPath
            let configPath = (expanded as NSString).appendingPathComponent(".git/config")
            if let content = try? String(contentsOfFile: configPath, encoding: .utf8),
               let remote = RepoScanner.extractOriginURL(fromGitConfig: content),
               let fullName = RepoScanner.parseGitHubRepoFullName(fromRemoteURL: remote),
               localRepos[fullName] == nil {
                localRepos[fullName] = URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }

        let explicitURL: URL? = {
            guard let raw = preferredLocalPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            let expanded = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
                ? URL(fileURLWithPath: expanded, isDirectory: true)
                : nil
        }()

        switch item.payload {
        case .codeChange(let code):
            return try await prepareCodeChangeWorktree(
                code: code,
                platform: item.platform,
                localRepos: localRepos,
                explicitRepoURL: explicitURL,
                useIsolatedWorktree: useIsolatedWorktree,
                previousReviewedSHA: previousReviewedSHA,
                gitPath: gitExecutablePath,
                env: environment
            )

        case .issueTicket(let ticket):
            if let explicitURL {
                return PreparedWorkspaceContext(workspaceURL: explicitURL)
            }
            if let linked = ticket.linkedRepository?.lowercased(), let localURL = localRepos[linked] {
                return PreparedWorkspaceContext(workspaceURL: localURL)
            }
            return try prepareEphemeralContextDirectory(for: item)

        case .conversation(let conv):
            if let explicitURL {
                return PreparedWorkspaceContext(workspaceURL: explicitURL)
            }
            if let linked = conv.linkedRepository?.lowercased(), let localURL = localRepos[linked] {
                return PreparedWorkspaceContext(workspaceURL: localURL)
            }
            return try prepareEphemeralContextDirectory(for: item)
        }
    }

    /// 供 Lody 原生 `--local-project --worktree --branch` 派发前静默刷新远端分支引用（不触碰用户当前工作区，兼容跨 Fork PR）
    public func refreshRemoteRefs(
        inRepositoryAt rootPath: String,
        code: CodeChangePayload,
        gitExecutablePath: String,
        environment: [String: String]
    ) async {
        guard FileManager.default.isExecutableFile(atPath: gitExecutablePath) else { return }
        let direct = await runner.run(
            executablePath: gitExecutablePath,
            arguments: [
                "-C", rootPath, "fetch", "--no-tags", "origin",
                "+refs/heads/\(code.headRef):refs/remotes/origin/\(code.headRef)",
                "+refs/heads/\(code.baseRef):refs/remotes/origin/\(code.baseRef)"
            ],
            environment: environment,
            timeoutSeconds: 45
        )
        if !direct.succeeded {
            // 跨 Fork PR 远端可能无 refs/heads/<headRef>，回退拉取 refs/pull/<number>/head
            _ = await runner.run(
                executablePath: gitExecutablePath,
                arguments: [
                    "-C", rootPath, "fetch", "--no-tags", "origin",
                    "+refs/pull/\(code.number)/head:refs/remotes/origin/\(code.headRef)",
                    "+refs/heads/\(code.baseRef):refs/remotes/origin/\(code.baseRef)"
                ],
                environment: environment,
                timeoutSeconds: 45
            )
        }
    }

    /// 复审场景：在本地仓库中拉取最新 PR 引用并计算 `previousSHA..最新HEAD` 的增量 Diff 与提交日志（若发生 force-push 自动回退全量）
    public func computeIncrementalChanges(
        inRepositoryAt rootPath: String,
        previousSHA: String,
        code: CodeChangePayload,
        gitExecutablePath: String,
        environment: [String: String]
    ) async -> (diff: String?, commitLog: String?, wasForcePushed: Bool) {
        guard FileManager.default.isExecutableFile(atPath: gitExecutablePath),
              !previousSHA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, nil, false)
        }
        let localRef = "refs/collabdock/pr-\(code.number)"
        let fetchPR = await runner.run(
            executablePath: gitExecutablePath,
            arguments: ["-C", rootPath, "fetch", "--no-tags", "origin", "pull/\(code.number)/head:\(localRef)", "--force"],
            environment: environment,
            timeoutSeconds: 45
        )
        _ = await runner.run(
            executablePath: gitExecutablePath,
            arguments: [
                "-C", rootPath, "fetch", "--no-tags", "origin",
                "+refs/heads/\(code.headRef):refs/remotes/origin/\(code.headRef)",
                "+refs/heads/\(code.baseRef):refs/remotes/origin/\(code.baseRef)"
            ],
            environment: environment,
            timeoutSeconds: 45
        )
        let headTarget = fetchPR.succeeded ? localRef : "origin/\(code.headRef)"
        return await computeIncrementalRange(
            inRepositoryAt: rootPath,
            previousSHA: previousSHA,
            headRef: headTarget,
            baseRef: code.baseRef,
            gitPath: gitExecutablePath,
            env: environment
        )
    }

    private func computeIncrementalRange(
        inRepositoryAt repoPath: String,
        previousSHA: String,
        headRef: String,
        baseRef: String,
        gitPath: String,
        env: [String: String]
    ) async -> (diff: String?, commitLog: String?, wasForcePushed: Bool) {
        let ancestorCheck = await runner.run(
            executablePath: gitPath,
            arguments: ["-C", repoPath, "merge-base", "--is-ancestor", previousSHA, headRef],
            environment: env,
            timeoutSeconds: 10
        )

        if ancestorCheck.succeeded {
            let diffRes = await runner.run(
                executablePath: gitPath,
                arguments: ["-C", repoPath, "diff", "\(previousSHA)..\(headRef)"],
                environment: env,
                timeoutSeconds: 20
            )
            let logRes = await runner.run(
                executablePath: gitPath,
                arguments: ["-C", repoPath, "log", "--oneline", "--max-count=30", "\(previousSHA)..\(headRef)"],
                environment: env,
                timeoutSeconds: 10
            )
            let diffText = diffRes.succeeded ? diffRes.stdout : nil
            let logText = logRes.succeeded ? logRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return (diffText, logText?.isEmpty == true ? nil : logText, false)
        } else {
            // 检测到 rebase / force-push，自动回退到相对 origin/<baseRef> 的最新全量 Diff
            let diffRes = await runner.run(
                executablePath: gitPath,
                arguments: ["-C", repoPath, "diff", "origin/\(baseRef)...\(headRef)"],
                environment: env,
                timeoutSeconds: 20
            )
            let logRes = await runner.run(
                executablePath: gitPath,
                arguments: ["-C", repoPath, "log", "--oneline", "--max-count=30", "origin/\(baseRef)..\(headRef)"],
                environment: env,
                timeoutSeconds: 10
            )
            let diffText = diffRes.succeeded ? diffRes.stdout : nil
            let logText = logRes.succeeded ? logRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return (diffText, logText?.isEmpty == true ? nil : logText, true)
        }
    }

    public func removeWorktree(
        baseRepositoryURL: URL,
        worktreeURL: URL,
        gitExecutablePath: String,
        environment: [String: String]
    ) async {
        _ = await runner.run(
            executablePath: gitExecutablePath,
            arguments: ["-C", baseRepositoryURL.path, "worktree", "remove", "--force", worktreeURL.path],
            environment: environment,
            timeoutSeconds: 15
        )
        try? FileManager.default.removeItem(at: worktreeURL)
    }

    // MARK: - Private

    private func prepareCodeChangeWorktree(
        code: CodeChangePayload,
        platform: PlatformKind,
        localRepos: [String: URL],
        explicitRepoURL: URL?,
        useIsolatedWorktree: Bool,
        previousReviewedSHA: String?,
        gitPath: String,
        env: [String: String]
    ) async throws -> PreparedWorkspaceContext {
        guard FileManager.default.isExecutableFile(atPath: gitPath) else {
            throw WorkspaceError.gitUnavailable
        }

        let repoKey = code.repository.lowercased()
        let baseRepoURL: URL
        if let explicitRepoURL {
            baseRepoURL = explicitRepoURL
        } else if let existing = localRepos[repoKey] {
            baseRepoURL = existing
        } else {
            baseRepoURL = try await ensureShallowCachedRepo(
                repository: code.repository,
                platform: platform,
                gitPath: gitPath,
                env: env
            )
        }

        // 1. 拉取目标 PR 与 base 分支（完全不触碰原仓库当前 checkout！）
        let prRef = "pull/\(code.number)/head"
        let localRef = "refs/collabdock/pr-\(code.number)"
        let fetchPR = await runner.run(
            executablePath: gitPath,
            arguments: ["-C", baseRepoURL.path, "fetch", "--no-tags", "origin", "\(prRef):\(localRef)", "--force"],
            environment: env,
            timeoutSeconds: 60
        )
        if !fetchPR.succeeded {
            // 兜底：尝试直接按分支名拉取
            let fallbackFetch = await runner.run(
                executablePath: gitPath,
                arguments: ["-C", baseRepoURL.path, "fetch", "--no-tags", "origin", code.headRef],
                environment: env,
                timeoutSeconds: 60
            )
            if !fallbackFetch.succeeded {
                throw WorkspaceError.fetchFailed(fetchPR.stderr.isEmpty ? fallbackFetch.stderr : fetchPR.stderr)
            }
        }

        _ = await runner.run(
            executablePath: gitPath,
            arguments: [
                "-C", baseRepoURL.path, "fetch", "--no-tags", "origin",
                "+refs/heads/\(code.baseRef):refs/remotes/origin/\(code.baseRef)"
            ],
            environment: env,
            timeoutSeconds: 45
        )

        let targetCommit = fetchPR.succeeded ? localRef : "FETCH_HEAD"
        var incDiff: String?
        var incLog: String?
        var forcePushed = false
        if let prevSHA = previousReviewedSHA, !prevSHA.isEmpty {
            let inc = await computeIncrementalRange(
                inRepositoryAt: baseRepoURL.path,
                previousSHA: prevSHA,
                headRef: targetCommit,
                baseRef: code.baseRef,
                gitPath: gitPath,
                env: env
            )
            incDiff = inc.diff
            incLog = inc.commitLog
            forcePushed = inc.wasForcePushed
        }

        // 若用户显式选择直接在主目录审查（不建 Worktree），仅计算 PR Diff，绝不切换用户当前分支
        if !useIsolatedWorktree {
            let diffRes = await runner.run(
                executablePath: gitPath,
                arguments: ["-C", baseRepoURL.path, "diff", "origin/\(code.baseRef)...\(targetCommit)"],
                environment: env,
                timeoutSeconds: 20
            )
            return PreparedWorkspaceContext(
                workspaceURL: baseRepoURL,
                baseRepositoryURL: baseRepoURL,
                isTemporaryWorktree: false,
                unifiedDiff: diffRes.succeeded ? diffRes.stdout : nil,
                incrementalDiff: incDiff,
                incrementalCommitLog: incLog,
                wasForcePushed: forcePushed
            )
        }

        // 2. 创建独立 detached worktree
        let worktreesRoot = cacheRootURL.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)

        let slug = sanitizePathComponent("\(code.repository)-pr-\(code.number)-\(code.headSHA.prefix(7))")
        let worktreeURL = worktreesRoot.appendingPathComponent(slug, isDirectory: true)

        if FileManager.default.fileExists(atPath: worktreeURL.path) {
            await removeWorktree(baseRepositoryURL: baseRepoURL, worktreeURL: worktreeURL, gitExecutablePath: gitPath, environment: env)
        }

        let addRes = await runner.run(
            executablePath: gitPath,
            arguments: ["-C", baseRepoURL.path, "worktree", "add", "--detach", "--force", worktreeURL.path, targetCommit],
            environment: env,
            timeoutSeconds: 45
        )
        guard addRes.succeeded else {
            throw WorkspaceError.worktreeFailed(addRes.stderr)
        }

        // 3. 在隔离 worktree 内计算标准 Unified Diff，供后续 DiffLineValidator 行号校验
        let diffRes = await runner.run(
            executablePath: gitPath,
            arguments: ["-C", worktreeURL.path, "diff", "origin/\(code.baseRef)...HEAD"],
            environment: env,
            timeoutSeconds: 20
        )
        let diffText = diffRes.succeeded ? diffRes.stdout : nil

        return PreparedWorkspaceContext(
            workspaceURL: worktreeURL,
            baseRepositoryURL: baseRepoURL,
            isTemporaryWorktree: true,
            unifiedDiff: diffText,
            incrementalDiff: incDiff,
            incrementalCommitLog: incLog,
            wasForcePushed: forcePushed
        )
    }

    private func ensureShallowCachedRepo(
        repository: String,
        platform: PlatformKind,
        gitPath: String,
        env: [String: String]
    ) async throws -> URL {
        let reposRoot = cacheRootURL.appendingPathComponent("repos", isDirectory: true)
        try FileManager.default.createDirectory(at: reposRoot, withIntermediateDirectories: true)
        let slug = sanitizePathComponent(repository)
        let cachedURL = reposRoot.appendingPathComponent(slug, isDirectory: true)

        if FileManager.default.fileExists(atPath: cachedURL.appendingPathComponent(".git").path) {
            return cachedURL
        }

        let host = (platform == .gitlab) ? "gitlab.com" : "github.com"
        let cloneURL = "https://\(host)/\(repository).git"
        let cloneRes = await runner.run(
            executablePath: gitPath,
            arguments: ["clone", "--filter=blob:none", "--no-checkout", cloneURL, cachedURL.path],
            environment: env,
            timeoutSeconds: 120
        )
        guard cloneRes.succeeded else {
            throw WorkspaceError.cloneFailed(cloneRes.stderr)
        }
        return cachedURL
    }

    private func prepareEphemeralContextDirectory(for item: CollaborationItem) throws -> PreparedWorkspaceContext {
        let root = cacheRootURL.appendingPathComponent("contexts", isDirectory: true)
        let dir = root.appendingPathComponent(sanitizePathComponent(item.id), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let contextMD = """
        # \(item.title)
        - Platform: \(item.platform.displayName)
        - Scope: \(item.scope) \(item.externalRef)
        - Author: @\(item.author)
        - Triggered By: @\(item.triggeredBy) (\(item.triggerKind.badgeText))

        ## Trigger Body
        \(item.triggerBody ?? "(empty)")
        """
        try contextMD.write(to: dir.appendingPathComponent("context.md"), atomically: true, encoding: .utf8)
        return PreparedWorkspaceContext(workspaceURL: dir)
    }

    private func sanitizePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
    }
}
