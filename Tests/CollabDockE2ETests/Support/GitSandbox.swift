import Foundation
@testable import CollabDockCore

/// 真实的本地 git 沙箱：一个 bare「远端」+ 一个用户本地克隆。
/// PR 头指针推送到远端的 `refs/pull/<n>/head`，与 GitHub 的 ref 布局一致，因此 WorktreeManager 走的是真实代码路径。
struct GitSandbox {
    let root: URL
    let origin: URL
    let userRepo: URL
    let cacheRoot: URL
    let gitPath = "/usr/bin/git"
    let env: [String: String]
    private let runner = DefaultProcessRunner()

    static var isGitAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/git") }

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-e2e-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        origin = root.appendingPathComponent("origin.git", isDirectory: true)
        userRepo = root.appendingPathComponent("work/backend", isDirectory: true)
        cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userRepo, withIntermediateDirectories: true)

        var e = ProcessInfo.processInfo.environment
        // 隔离用户全局 git 配置（签名、hooks、模板等都可能让测试不稳定）
        e["GIT_CONFIG_GLOBAL"] = "/dev/null"
        e["GIT_CONFIG_NOSYSTEM"] = "1"
        e["GIT_AUTHOR_NAME"] = "E2E"
        e["GIT_AUTHOR_EMAIL"] = "e2e@example.com"
        e["GIT_COMMITTER_NAME"] = "E2E"
        e["GIT_COMMITTER_EMAIL"] = "e2e@example.com"
        env = e

        try await git(["init", "--bare", origin.path])
        try await git(["init", "-b", "main", userRepo.path])
        try await git(["-C", userRepo.path, "remote", "add", "origin", origin.path])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func git(_ args: [String]) async throws -> String {
        let out = await runner.run(executablePath: gitPath, arguments: args, environment: env, timeoutSeconds: 30)
        guard out.succeeded else {
            throw SandboxError.gitFailed(args.joined(separator: " "), out.stderr)
        }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ relativePath: String, _ content: String) throws {
        let url = userRepo.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 提交当前工作区并返回新的 HEAD SHA
    @discardableResult
    func commitAll(_ message: String) async throws -> String {
        try await git(["-C", userRepo.path, "add", "-A"])
        try await git(["-C", userRepo.path, "commit", "-q", "-m", message])
        return try await git(["-C", userRepo.path, "rev-parse", "HEAD"])
    }

    /// 把当前分支推送为 PR 头：同时更新分支 ref 与 `refs/pull/<n>/head`
    func publishPullRequest(number: Int, branch: String, force: Bool = false) async throws {
        var args = ["-C", userRepo.path, "push", "-q", "origin", "HEAD:refs/heads/\(branch)", "HEAD:refs/pull/\(number)/head"]
        if force { args.insert("--force", at: 4) }
        try await git(args)
    }

    func currentBranch() async throws -> String {
        try await git(["-C", userRepo.path, "rev-parse", "--abbrev-ref", "HEAD"])
    }

    enum SandboxError: Error, CustomStringConvertible {
        case gitFailed(String, String)
        var description: String {
            switch self {
            case .gitFailed(let cmd, let err): return "git \(cmd) failed: \(err)"
            }
        }
    }
}
