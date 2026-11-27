import Foundation
import Testing
@testable import CollabDockCore

/// 环境探测的编排逻辑（此前只测了各个解析函数）：二进制定位、版本探测、gh 登录态、token 优先级、agy 模型、Lody 目录与会话用量。
/// 全部通过 FakeProcessRunner + 临时目录里的假二进制完成，不依赖本机安装了什么。
@Suite("EnvironmentDetector — detection orchestration with a fake process runner")
struct EnvironmentDetectionTests {
    static let ghAuthLoggedIn = """
    github.com
      ✓ Logged in to github.com account alice (keyring)
      - Active account: true
      - Token scopes: 'gist', 'notifications', 'read:org', 'repo'
    """
    static let agyModels = """
    Fetching available models...
    gemini-4-neon-xhigh\tGemini 4 Neon (XHigh)
    claude-opus-5-5-high\tClaude Opus 5.5 (High)
    """

    private func scriptedRunner() -> FakeProcessRunner {
        let r = FakeProcessRunner()
        r.on("git", ["--version"], stdout: "git version 2.48.0\n")
        r.on("gh", ["--version"], stdout: "gh version 2.65.0 (2026-01-10)\nhttps://github.com/cli/cli/releases/tag/v2.65.0\n")
        r.on("claude", ["--version"], stdout: "2.1.0 (Claude Code)\n")
        r.on("codex", ["--version"], stdout: "codex-cli 0.159.2\n")
        r.on("agy", ["--version"], stdout: "\n  agy 1.4.0\n")
        r.on("lody", ["--version"], stdout: "0.9.3\n")
        r.on("gh", ["auth", "status"], stderr: Self.ghAuthLoggedIn)
        r.on("gh", ["api", "user"], stdout: #"{"login":"alice","name":"Alice A.","avatar_url":"https://avatars.githubusercontent.com/u/1?v=4"}"#)
        r.on("agy", ["models"], stdout: Self.agyModels)
        return r
    }

    private func overrides(_ bins: FakeBinaries, _ names: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, bins.path($0)) })
    }

    @Test("detectAll probes every CLI, reads versions, GitHub login + scopes and the live agy model list")
    func detectAllHappyPath() async throws {
        let names = ["git", "gh", "claude", "codex", "agy", "lody"]
        let bins = try FakeBinaries(names)
        defer { bins.cleanup() }
        let runner = scriptedRunner()

        let snap = await EnvironmentDetector(runner: runner).detectAll(customPaths: overrides(bins, names))

        #expect(snap.git.isInstalled && snap.git.version == "git version 2.48.0")
        #expect(snap.gh.executablePath == bins.path("gh"))
        #expect(snap.gh.version == "gh version 2.65.0 (2026-01-10)")
        #expect(snap.engines[.claudeCode]?.version == "2.1.0 (Claude Code)")
        #expect(snap.engines[.codex]?.version == "codex-cli 0.159.2")
        #expect(snap.engines[.antigravity]?.version == "agy 1.4.0", "first non-empty line, trimmed")
        #expect(snap.engines[.lody]?.executablePath == bins.path("lody"))
        #expect(AgentEngine.allCases.allSatisfy { snap.isEngineReady($0) })

        #expect(snap.githubAuth.isAuthenticated)
        #expect(snap.githubAuth.tokenSource == .ghCLI)
        #expect(snap.githubAuth.username == "alice")
        #expect(snap.githubAuth.displayName == "Alice A.")
        #expect(snap.githubAuth.avatarURL == "https://avatars.githubusercontent.com/u/1?v=4")
        #expect(snap.githubAuth.hasNotificationsScope)

        #expect(snap.discoveredModels[.antigravity]?.map(\.id) == ["gemini-4-neon-xhigh", "claude-opus-5-5-high"])
        #expect(snap.discoveredModels[.claudeCode] == AgentEngine.claudeCode.defaultModels)
        #expect(snap.discoveredModels[.codex] == AgentEngine.codex.defaultModels)
    }

    @Test("Missing CLIs are reported as not installed; no gh → not authenticated, no agy → built-in model list")
    func detectAllWithMissingTools() async throws {
        let bins = try FakeBinaries(["git", "claude"])
        defer { bins.cleanup() }
        let runner = scriptedRunner()
        let missing = bins.dir.appendingPathComponent("does-not-exist").path

        let snap = await EnvironmentDetector(runner: runner).detectAll(customPaths: [
            "git": bins.path("git"), "claude": bins.path("claude"),
            "gh": missing, "codex": missing, "agy": missing
        ])

        #expect(snap.gh.isInstalled == false)
        #expect(snap.gh.errorMessage?.contains("gh") == true)
        #expect(snap.engines[.codex]?.isInstalled == false)
        #expect(snap.engines[.antigravity]?.isInstalled == false)
        #expect(snap.engines[.claudeCode]?.isInstalled == true)
        #expect(snap.githubAuth.isAuthenticated == false)
        #expect(snap.githubAuth.tokenSource == GitHubTokenSource.none)
        #expect(snap.discoveredModels[.antigravity] == AgentEngine.antigravity.defaultModels)
        #expect(runner.calls(to: "gh").isEmpty)
        #expect(runner.calls(to: "agy").isEmpty)
    }

    @Test("gh installed but logged out: not authenticated with a login hint, profile is not fetched")
    func ghLoggedOut() async throws {
        let bins = try FakeBinaries(["gh"])
        defer { bins.cleanup() }
        let runner = FakeProcessRunner()
        runner.on("gh", ["--version"], stdout: "gh version 2.65.0\n")
        runner.on("gh", ["auth", "status"], stderr: "You are not logged into any GitHub hosts. To log in, run: gh auth login", exitCode: 1)

        let snap = await EnvironmentDetector(runner: runner).detectAll(customPaths: ["gh": bins.path("gh")])

        #expect(snap.githubAuth.isAuthenticated == false)
        #expect(snap.githubAuth.errorMessage?.contains("gh auth login") == true)
        #expect(!runner.calls(to: "gh").contains(["api", "user"]))
    }

    @Test("A manual PAT short-circuits gh: authenticated as manualPAT without calling `gh auth status`")
    func manualPATWins() async throws {
        let bins = try FakeBinaries(["gh"])
        defer { bins.cleanup() }
        let runner = scriptedRunner()

        let snap = await EnvironmentDetector(runner: runner).detectAll(customPaths: ["gh": bins.path("gh")], manualGitHubPAT: "  github_pat_placeholder  ")

        #expect(snap.githubAuth.isAuthenticated)
        #expect(snap.githubAuth.tokenSource == .manualPAT)
        #expect(!runner.calls(to: "gh").contains(["auth", "status"]))
    }

    @Test("Token resolution: a non-blank manual PAT wins; otherwise `gh auth token`, and failures or empty output give nil")
    func tokenResolution() async throws {
        let bins = try FakeBinaries(["gh"])
        defer { bins.cleanup() }

        let ok = FakeProcessRunner()
        ok.on("gh", ["auth", "token"], stdout: "gho_placeholder_token\n")
        let detector = EnvironmentDetector(runner: ok)
        #expect(await detector.resolveGitHubToken(ghExecutablePath: bins.path("gh"), manualPAT: "pat-123") == "pat-123")
        #expect(ok.calls(to: "gh").isEmpty)
        #expect(await detector.resolveGitHubToken(ghExecutablePath: bins.path("gh"), manualPAT: "   ") == "gho_placeholder_token")
        #expect(await detector.resolveGitHubToken(ghExecutablePath: bins.path("gh")) == "gho_placeholder_token")

        let failing = FakeProcessRunner()
        failing.on("gh", ["auth", "token"], stderr: "no oauth token", exitCode: 1)
        #expect(await EnvironmentDetector(runner: failing).resolveGitHubToken(ghExecutablePath: bins.path("gh")) == nil)

        let empty = FakeProcessRunner()
        empty.on("gh", ["auth", "token"], stdout: "\n")
        #expect(await EnvironmentDetector(runner: empty).resolveGitHubToken(ghExecutablePath: bins.path("gh")) == nil)
    }

    // MARK: Lody

    static let lodyAgents = #"{"ok":true,"workspaceId":"ws_123","items":[{"id":"cfg-agy","name":"Antigravity","agentType":"antigravity","runConfig":{"modes":[{"id":"plan","name":"Plan"}],"models":[{"id":"gemini-4-neon","name":"Gemini 4 Neon"}]}}]}"#
    static let lodyWorkspaces = #"{"ok":true,"workspaces":[{"id":"ws_123","name":"Demo workspace","slug":"demo"}]}"#
    static let lodyProjects = #"{"ok":true,"type":"local-project/list","result":{"workspaces":[{"workspaceId":"ws_123","projects":[{"localProjectId":"lp-1","name":"backend","rootPath":"/tmp/nonexistent/backend"}]}]}}"#
    static let lodyRepos = #"{"ok":true,"repositories":[{"fullName":"acme/backend"},{"owner":"acme","name":"web"}]}"#

    private func lodyProbe(_ path: String) -> CLIProbeStatus {
        CLIProbeStatus(name: "lody", isInstalled: true, executablePath: path)
    }

    @Test("Lody catalog: agent configs, workspaces, local projects and linked repos are fetched (workspace-scoped where supported)")
    func lodyCatalogDirect() async throws {
        let bins = try FakeBinaries(["lody"])
        defer { bins.cleanup() }
        let r = FakeProcessRunner()
        r.on("lody", ["agent-config", "list", "--json", "--workspace", "ws_123"], stdout: Self.lodyAgents)
        r.on("lody", ["workspace", "list", "--json"], stdout: Self.lodyWorkspaces)
        r.on("lody", ["project", "list", "--json"], stdout: Self.lodyProjects)
        r.on("lody", ["github", "list", "--json", "--workspace", "ws_123"], stdout: Self.lodyRepos)

        let catalog = await EnvironmentDetector(runner: r).fetchLodyCatalog(lodyProbe: lodyProbe(bins.path("lody")), workspace: "ws_123", resolvedPATH: "/usr/bin")

        #expect(catalog?.workspaceID == "ws_123")
        #expect(catalog?.workspaces.map(\.name) == ["Demo workspace"])
        #expect(catalog?.agentConfigs.map(\.id) == ["cfg-agy"])
        #expect(catalog?.localProjects.map(\.id) == ["lp-1"])
        #expect(catalog?.linkedGitHubRepos == ["acme/backend", "acme/web"])
        #expect(catalog?.hasLinkedGitHubRepo("ACME/Backend") == true)
    }

    @Test("Lody catalog through npx pins lody@latest; .app paths, missing installs and empty answers yield nil")
    func lodyCatalogEdgeCases() async throws {
        let bins = try FakeBinaries(["npx"])
        defer { bins.cleanup() }
        let r = FakeProcessRunner()
        r.on("npx", ["-y", "lody@latest", "workspace", "list", "--json"], stdout: Self.lodyWorkspaces)
        let detector = EnvironmentDetector(runner: r)

        let viaNPX = await detector.fetchLodyCatalog(lodyProbe: lodyProbe(bins.path("npx")), resolvedPATH: "/usr/bin")
        #expect(viaNPX?.workspaceID == "ws_123")
        #expect(r.calls(to: "npx").allSatisfy { Array($0.prefix(2)) == ["-y", "lody@latest"] })
        #expect(r.calls(to: "npx").count == 4)

        #expect(await detector.fetchLodyCatalog(lodyProbe: lodyProbe("/Applications/Lody.app"), resolvedPATH: "/usr/bin") == nil)
        #expect(await detector.fetchLodyCatalog(lodyProbe: CLIProbeStatus(name: "lody", isInstalled: false), resolvedPATH: "/usr/bin") == nil)

        let silent = FakeProcessRunner()
        #expect(await EnvironmentDetector(runner: silent).fetchLodyCatalog(lodyProbe: lodyProbe(bins.path("npx")), resolvedPATH: "/usr/bin") == nil)
    }

    @Test("Lody session usage is read with `session show <id> --json` and parsed into a usage snapshot")
    func lodySessionUsage() async throws {
        let bins = try FakeBinaries(["lody"])
        defer { bins.cleanup() }
        let r = FakeProcessRunner()
        r.on("lody", ["session", "show", "sess-1", "--json", "--workspace", "ws_123"],
             stdout: #"{"ok":true,"session":{"id":"sess-1","status":{"type":"idle"},"contextWindowUsage":{"used":4200},"lastModel":{"modelId":"gemini-4-neon","name":"Gemini 4 Neon"}}}"#)
        let detector = EnvironmentDetector(runner: r)

        let snap = await detector.fetchLodySessionUsage(lodyProbe: lodyProbe(bins.path("lody")), sessionID: "sess-1", workspace: "ws_123", resolvedPATH: "/usr/bin")
        #expect(snap?.sessionID == "sess-1")
        #expect(snap?.contextUsedTokens == 4200)
        #expect(snap?.modelID == "gemini-4-neon")
        #expect(snap?.isSettledIdle == true)

        #expect(await detector.fetchLodySessionUsage(lodyProbe: lodyProbe(bins.path("lody")), sessionID: "unknown", resolvedPATH: "/usr/bin") == nil)
        #expect(await detector.fetchLodySessionUsage(lodyProbe: lodyProbe("/Applications/Lody.app"), sessionID: "sess-1", resolvedPATH: "/usr/bin") == nil)
    }
}
