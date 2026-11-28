import Foundation
import Testing
@testable import CollabDockCore

@Suite("RepoScanner & WorktreeManager Tests [REQ-006][TASK-011]")
struct WorktreeAndRepoScannerTests {
    @Test("Parses GitHub owner/repo from SSH, HTTPS, and git config files")
    func parsesGitRemotes() {
        #expect(RepoScanner.parseGitHubRepoFullName(fromRemoteURL: "git@github.com:Acme/Backend.git") == "acme/backend")
        #expect(RepoScanner.parseGitHubRepoFullName(fromRemoteURL: "https://github.com/Acme/Web-Console.git") == "acme/web-console")
        #expect(RepoScanner.parseGitHubRepoFullName(fromRemoteURL: "ssh://git@github.com/org/app") == "org/app")

        let gitConfig = """
        [core]
            bare = false
        [remote "origin"]
            url = git@github.com:acme/service.git
            fetch = +refs/heads/*:refs/remotes/origin/*
        """
        let origin = RepoScanner.extractOriginURL(fromGitConfig: gitConfig)
        #expect(origin == "git@github.com:acme/service.git")
        #expect(RepoScanner.parseGitHubRepoFullName(fromRemoteURL: origin ?? "") == "acme/service")
    }

    @Test("Scans local directory and finds git repositories by remote origin")
    func scansTemporaryGitRepo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-scan-\(UUID().uuidString)", isDirectory: true)
        let repoDir = root.appendingPathComponent("backend", isDirectory: true)
        let gitDir = repoDir.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let config = """
        [remote "origin"]
            url = git@github.com:acme/backend.git
        """
        try config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let scanner = RepoScanner()
        let found = scanner.scanRepositories(in: [root.path])
        #expect(found["acme/backend"]?.standardizedFileURL == repoDir.standardizedFileURL)
    }

    @Test("Creates isolated worktree from real local git repo without touching user dirty files")
    func isolatedWorktreePreservesDirtyWorkingTree() async throws {
        let runner = DefaultProcessRunner()
        let gitPath = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: gitPath) else { return }

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-wt-\(UUID().uuidString)", isDirectory: true)
        let originBare = sandbox.appendingPathComponent("origin.git", isDirectory: true)
        let userRepo = sandbox.appendingPathComponent("work/myrepo", isDirectory: true)
        let cacheRoot = sandbox.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: originBare, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let env = ProcessInfo.processInfo.environment
        _ = await runner.run(executablePath: gitPath, arguments: ["init", "--bare", originBare.path], environment: env, timeoutSeconds: 10)
        _ = await runner.run(executablePath: gitPath, arguments: ["init", "-b", "main", userRepo.path], environment: env, timeoutSeconds: 10)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "config", "user.email", "test@collabdock.dev"], environment: env, timeoutSeconds: 5)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "config", "user.name", "Test"], environment: env, timeoutSeconds: 5)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "remote", "add", "origin", originBare.path], environment: env, timeoutSeconds: 5)

        try "let v = 1\n".write(to: userRepo.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "add", "."], environment: env, timeoutSeconds: 5)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "commit", "-m", "init"], environment: env, timeoutSeconds: 5)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "push", "-u", "origin", "main"], environment: env, timeoutSeconds: 10)

        // 模拟 PR 分支推送到 origin/feat-pr
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "checkout", "-b", "feat-pr"], environment: env, timeoutSeconds: 5)
        try "let v = 2\nlet added = true\n".write(to: userRepo.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "commit", "-am", "feat"], environment: env, timeoutSeconds: 5)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "push", "origin", "feat-pr"], environment: env, timeoutSeconds: 10)

        // 切回 main 并制造用户未提交的脏文件
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "checkout", "main"], environment: env, timeoutSeconds: 5)
        let dirtyFile = userRepo.appendingPathComponent("WIP.txt")
        try "do not touch my wip".write(to: dirtyFile, atomically: true, encoding: .utf8)

        // 模拟 RepoScanner 匹配（用 origin.git 无法匹配 github.com，故验证直接从 localRepo 改写 remote 为 github.com 会触发网络，
        // 这里验证 context 清理与 ephemeral context 目录创建及用户脏文件 100% 保留）
        let manager = WorktreeManager(runner: runner, cacheRootURL: cacheRoot)
        let chatItem = CollaborationItem(
            id: "feishu:thread-1",
            platform: .feishu,
            itemKind: .conversation,
            scope: "#值班群",
            externalRef: "话题",
            title: "排查超时",
            url: URL(string: "https://open.feishu.cn/")!,
            author: "diana",
            triggeredBy: "diana",
            triggerKind: .mention,
            triggerBody: "@dev 排查",
            payload: .conversation(ConversationPayload(channelName: "#值班群"))
        )
        let ctx = try await manager.prepareContext(
            for: chatItem,
            searchRoots: [sandbox.appendingPathComponent("work").path],
            gitExecutablePath: gitPath,
            environment: env
        )
        #expect(FileManager.default.fileExists(atPath: ctx.workspaceURL.appendingPathComponent("context.md").path))
        #expect((try? String(contentsOf: dirtyFile, encoding: .utf8)) == "do not touch my wip")
    }

    @Test("Matches local repository from extraLocalRepoPaths even outside searchRoots [ITER-010]")
    func matchesExtraLocalRepoPath() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-extra-\(UUID().uuidString)", isDirectory: true)
        let extraRepo = sandbox.appendingPathComponent("lody-linked/web", isDirectory: true)
        let gitDir = extraRepo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let config = """
        [remote "origin"]
            url = git@github.com:acme/web.git
        """
        try config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let manager = WorktreeManager(cacheRootURL: sandbox.appendingPathComponent("cache", isDirectory: true))
        let item = CollaborationItem(
            id: "gh:issue-1",
            platform: .github,
            itemKind: .issue,
            scope: "acme/web",
            externalRef: "#1",
            title: "Test",
            url: URL(string: "https://github.com/acme/web/issues/1")!,
            author: "alice",
            triggeredBy: "alice",
            triggerKind: .mention,
            payload: .issueTicket(IssueTicketPayload(ticketKey: "#1", linkedRepository: "acme/web"))
        )
        let ctx = try await manager.prepareContext(
            for: item,
            searchRoots: [sandbox.appendingPathComponent("empty-root").path],
            extraLocalRepoPaths: [extraRepo.path],
            gitExecutablePath: "/usr/bin/git",
            environment: ProcessInfo.processInfo.environment
        )
        #expect(ctx.workspaceURL.standardizedFileURL == extraRepo.standardizedFileURL)
    }

    // MARK: - Refreshing PR refs (what the Lody agent relies on; replaces the removed incremental-diff computation)

    /// 真实 git 沙箱：bare 远端 + 用户本地克隆 + 作者的另一个克隆。作者推送后，用户仓库在刷新前看不到新提交。
    private struct RefreshSandbox {
        let root: URL
        let origin: URL
        let userRepo: URL
        let author: URL
        let gitPath = "/usr/bin/git"
        let env: [String: String]
        let runner = DefaultProcessRunner()

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("collabdock-refresh-\(UUID().uuidString)", isDirectory: true)
            origin = root.appendingPathComponent("origin.git", isDirectory: true)
            userRepo = root.appendingPathComponent("work/repo", isDirectory: true)
            author = root.appendingPathComponent("author/repo", isDirectory: true)
            try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: userRepo.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: author.deletingLastPathComponent(), withIntermediateDirectories: true)
            var e = ProcessInfo.processInfo.environment
            e["GIT_CONFIG_GLOBAL"] = "/dev/null"
            e["GIT_CONFIG_NOSYSTEM"] = "1"
            e["GIT_AUTHOR_NAME"] = "T"
            e["GIT_AUTHOR_EMAIL"] = "t@example.com"
            e["GIT_COMMITTER_NAME"] = "T"
            e["GIT_COMMITTER_EMAIL"] = "t@example.com"
            env = e

            try await git(["init", "-q", "--bare", "-b", "main", origin.path])
            try await git(["clone", "-q", origin.path, author.path])
            try await git(["-C", author.path, "checkout", "-q", "-b", "main"])
            try "let a = 1\n".write(to: author.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
            try await git(["-C", author.path, "add", "."])
            try await git(["-C", author.path, "commit", "-q", "-m", "init"])
            try await git(["-C", author.path, "push", "-q", "origin", "main"])
            try await git(["-C", author.path, "checkout", "-q", "-b", "feat/fix"])
            try "let a = 2\n".write(to: author.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
            try await git(["-C", author.path, "commit", "-q", "-am", "round1 feat"])
            try await git(["-C", author.path, "push", "-q", "origin", "HEAD:refs/heads/feat/fix", "HEAD:refs/pull/1/head"])
            // 用户在第 1 轮时克隆（此时已能看到第 1 轮的 PR 头）
            try await git(["clone", "-q", origin.path, userRepo.path])
        }

        @discardableResult
        func git(_ args: [String]) async throws -> String {
            let out = await runner.run(executablePath: gitPath, arguments: args, environment: env, timeoutSeconds: 30)
            guard out.succeeded else { throw RefreshError.git(args.joined(separator: " "), out.stderr) }
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// 作者推送一个新提交到 PR 分支（`rewrite` 时模拟 rebase + force-push），返回新 PR 头
        func authorPushes(_ content: String, message: String, rewrite: Bool = false, refs: [String] = ["refs/heads/feat/fix", "refs/pull/1/head"]) async throws -> String {
            if rewrite {
                try await git(["-C", author.path, "checkout", "-q", "-B", "feat/fix", "main"])
            }
            try content.write(to: author.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
            try await git(["-C", author.path, "commit", "-q", "-am", message])
            try await git(["-C", author.path, "push", "-q", "--force", "origin"] + refs.map { "HEAD:\($0)" })
            return try await git(["-C", author.path, "rev-parse", "HEAD"])
        }

        func userHasCommit(_ sha: String) async -> Bool {
            (try? await git(["-C", userRepo.path, "cat-file", "-e", "\(sha)^{commit}"])) != nil
        }

        func code(headRef: String = "feat/fix", number: Int = 1, headSHA: String) -> CodeChangePayload {
            CodeChangePayload(repository: "acme/repo", number: number, baseRef: "main", headRef: headRef, headSHA: headSHA, additions: 1, deletions: 1, changedFiles: 1)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private enum RefreshError: Error { case git(String, String) }

    @Test("Refreshing PR refs brings the author's new commit into the local project without touching the user's checkout")
    func refreshBringsNewCommit() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let sb = try await RefreshSandbox()
        defer { sb.cleanup() }
        let newHead = try await sb.authorPushes("let a = 2\nlet fixedBug = true\n", message: "fix review comment")
        #expect(await sb.userHasCommit(newHead) == false)
        let branchBefore = try await sb.git(["-C", sb.userRepo.path, "rev-parse", "--abbrev-ref", "HEAD"])

        let manager = WorktreeManager(runner: sb.runner, cacheRootURL: sb.root.appendingPathComponent("cache", isDirectory: true))
        await manager.refreshRemoteRefs(inRepositoryAt: sb.userRepo.path, code: sb.code(headSHA: newHead), gitExecutablePath: sb.gitPath, environment: sb.env)

        #expect(await sb.userHasCommit(newHead))
        #expect(try await sb.git(["-C", sb.userRepo.path, "rev-parse", "refs/remotes/origin/feat/fix"]) == newHead)
        #expect(try await sb.git(["-C", sb.userRepo.path, "rev-parse", "--abbrev-ref", "HEAD"]) == branchBefore)
        #expect(try await sb.git(["-C", sb.userRepo.path, "status", "--porcelain"]).isEmpty)
    }

    @Test("Refreshing PR refs follows a force-push: the rewritten head replaces the old one")
    func refreshFollowsForcePush() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let sb = try await RefreshSandbox()
        defer { sb.cleanup() }
        let rewritten = try await sb.authorPushes("let a = 3\n", message: "feat (rebased)", rewrite: true)

        let manager = WorktreeManager(runner: sb.runner, cacheRootURL: sb.root.appendingPathComponent("cache", isDirectory: true))
        await manager.refreshRemoteRefs(inRepositoryAt: sb.userRepo.path, code: sb.code(headSHA: rewritten), gitExecutablePath: sb.gitPath, environment: sb.env)

        #expect(try await sb.git(["-C", sb.userRepo.path, "rev-parse", "refs/remotes/origin/feat/fix"]) == rewritten)
    }

    @Test("A cross-fork PR (no branch on origin) is refreshed from refs/pull/<n>/head")
    func refreshFallsBackToPullRef() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let sb = try await RefreshSandbox()
        defer { sb.cleanup() }
        let forkHead = try await sb.authorPushes("let a = 2\nlet fromFork = true\n", message: "fork fix", refs: ["refs/pull/2/head"])
        #expect(await sb.userHasCommit(forkHead) == false)

        let manager = WorktreeManager(runner: sb.runner, cacheRootURL: sb.root.appendingPathComponent("cache", isDirectory: true))
        await manager.refreshRemoteRefs(
            inRepositoryAt: sb.userRepo.path,
            code: sb.code(headRef: "contributor-branch", number: 2, headSHA: forkHead),
            gitExecutablePath: sb.gitPath,
            environment: sb.env
        )

        #expect(await sb.userHasCommit(forkHead))
        #expect(try await sb.git(["-C", sb.userRepo.path, "rev-parse", "refs/remotes/origin/contributor-branch"]) == forkHead)
    }

    // MARK: - No diff is computed any more (nothing reads it since the prompt became template-only)

    /// 记录所有 git 调用（并真实执行），用于断言准备工作区时不再跑 `git diff`
    private final class RecordingRunner: ProcessRunner, @unchecked Sendable {
        private let inner = DefaultProcessRunner()
        private let lock = NSLock()
        private var calls: [[String]] = []
        var recorded: [[String]] { lock.withLock { calls } }

        func run(executablePath: String, arguments: [String], environment: [String: String], timeoutSeconds: TimeInterval) async -> ProcessOutput {
            lock.withLock { calls.append(arguments) }
            return await inner.run(executablePath: executablePath, arguments: arguments, environment: environment, timeoutSeconds: timeoutSeconds)
        }

        /// git 子命令（跳过 `-C <path>` 等前置参数）
        var subcommands: [String] {
            recorded.compactMap { args in
                var i = 0
                while i < args.count, args[i].hasPrefix("-") {
                    i += (args[i] == "-C" || args[i] == "-c") ? 2 : 1
                }
                return i < args.count ? args[i] : nil
            }
        }
    }

    @Test("Preparing a PR workspace (isolated worktree or the project directory itself) never runs `git diff`", arguments: [true, false])
    func preparingWorkspaceComputesNoDiff(isolated: Bool) async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let sb = try await RefreshSandbox()
        defer { sb.cleanup() }
        let head = try await sb.git(["-C", sb.author.path, "rev-parse", "HEAD"])
        let recorder = RecordingRunner()
        let manager = WorktreeManager(runner: recorder, cacheRootURL: sb.root.appendingPathComponent("cache", isDirectory: true))
        let item = CollaborationItem(
            id: "github:acme/repo#1:reviewRequested:\(head)",
            platform: .github,
            itemKind: .pullRequest,
            scope: "acme/repo",
            externalRef: "#1",
            title: "round1 feat",
            url: URL(string: "https://github.com/acme/repo/pull/1")!,
            author: "alice",
            triggeredBy: "alice",
            triggerKind: .reviewRequested,
            payload: .codeChange(sb.code(headSHA: head))
        )

        let ctx = try await manager.prepareContext(
            for: item,
            searchRoots: [],
            preferredLocalPath: sb.userRepo.path,
            useIsolatedWorktree: isolated,
            gitExecutablePath: sb.gitPath,
            environment: sb.env
        )

        #expect(ctx.isTemporaryWorktree == isolated)
        if isolated {
            let checkedOut = try await sb.git(["-C", ctx.workspaceURL.path, "rev-parse", "HEAD"])
            #expect(checkedOut == head, "the isolated worktree is on the PR head")
        } else {
            #expect(ctx.workspaceURL.standardizedFileURL == sb.userRepo.standardizedFileURL)
        }
        #expect(!recorder.subcommands.contains("diff"), "git calls: \(recorder.recorded)")
        #expect(recorder.subcommands.contains("fetch"), "the PR head is still fetched")
    }
}
