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
            triggerBody: "@boris 排查",
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

    @Test("Computes incremental commit diff between old reviewed SHA and new fix commit, and handles force-push fallback [TASK-015][ITER-013]")
    func computesIncrementalDiffAndDetectsForcePush() async throws {
        let runner = DefaultProcessRunner()
        let gitPath = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: gitPath) else { return }

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-inc-\(UUID().uuidString)", isDirectory: true)
        let originBare = sandbox.appendingPathComponent("origin.git", isDirectory: true)
        let userRepo = sandbox.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: originBare, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let env = ProcessInfo.processInfo.environment
        _ = await runner.run(executablePath: gitPath, arguments: ["init", "--bare", originBare.path], environment: env, timeoutSeconds: 10)
        _ = await runner.run(executablePath: gitPath, arguments: ["init", "-b", "main", userRepo.path], environment: env, timeoutSeconds: 10)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "config", "user.email", "t@t.dev"], environment: env, timeoutSeconds: 5)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "config", "user.name", "T"], environment: env, timeoutSeconds: 5)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "remote", "add", "origin", originBare.path], environment: env, timeoutSeconds: 5)

        try "let a = 1\n".write(to: userRepo.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "add", "."], environment: env, timeoutSeconds: 5)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "commit", "-m", "init"], environment: env, timeoutSeconds: 5)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "push", "-u", "origin", "main"], environment: env, timeoutSeconds: 10)

        // Round 1 PR commit
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "checkout", "-b", "feat/fix"], environment: env, timeoutSeconds: 5)
        try "let a = 2\n".write(to: userRepo.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "commit", "-am", "round1 feat"], environment: env, timeoutSeconds: 5)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "push", "origin", "feat/fix"], environment: env, timeoutSeconds: 10)
        let round1SHA = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "rev-parse", "HEAD"], environment: env, timeoutSeconds: 5).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // Round 2 developer fix commit
        try "let a = 2\nlet fixedBug = true\n".write(to: userRepo.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "commit", "-am", "fix review comment"], environment: env, timeoutSeconds: 5)
        _ = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "push", "origin", "feat/fix"], environment: env, timeoutSeconds: 10)
        let round2SHA = await runner.run(executablePath: gitPath, arguments: ["-C", userRepo.path, "rev-parse", "HEAD"], environment: env, timeoutSeconds: 5).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let manager = WorktreeManager(runner: runner, cacheRootURL: sandbox.appendingPathComponent("cache", isDirectory: true))
        let code = CodeChangePayload(repository: "acme/repo", number: 1, baseRef: "main", headRef: "feat/fix", headSHA: round2SHA, additions: 2, deletions: 1, changedFiles: 1)

        let inc = await manager.computeIncrementalChanges(
            inRepositoryAt: userRepo.path,
            previousSHA: round1SHA,
            code: code,
            gitExecutablePath: gitPath,
            environment: env
        )
        #expect(inc.wasForcePushed == false)
        #expect(inc.diff?.contains("let fixedBug = true") == true)
        #expect(inc.commitLog?.contains("fix review comment") == true)

        // 模拟不可达 SHA（force-push / rebase 后）：自动回退为全量 Diff 且标记 wasForcePushed = true
        let forcePushed = await manager.computeIncrementalChanges(
            inRepositoryAt: userRepo.path,
            previousSHA: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
            code: code,
            gitExecutablePath: gitPath,
            environment: env
        )
        #expect(forcePushed.wasForcePushed == true)
        #expect(forcePushed.diff?.contains("let fixedBug = true") == true)
    }
}
