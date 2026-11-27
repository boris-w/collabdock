import Testing
@testable import CollabDockCore

@Suite("EnvironmentDetector Tests [REQ-001][TASK-004]")
struct EnvironmentDetectorTests {
    @Test("Parses agy models TSV output skipping status headers")
    func parsesAgyModelsOutput() {
        let raw = """
        Fetching available models...
        gemini-4-neon-xhigh\tGemini 4 Neon (XHigh)
        claude-opus-5-5-high\tClaude Opus 5.5 (High)
        gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
        """
        let models = EnvironmentDetector.parseAgyModelsOutput(raw)
        #expect(models.count == 3)
        #expect(models[0] == ModelOption(id: "gemini-4-neon-xhigh", displayName: "Gemini 4 Neon (XHigh)"))
        #expect(models[1] == ModelOption(id: "claude-opus-5-5-high", displayName: "Claude Opus 5.5 (High)"))
    }

    @Test("Parses gh auth status username and OAuth scopes accurately")
    func parsesGHAuthStatus() {
        let output = """
        github.com
          ✓ Logged in to github.com account boris-w (keyring)
          - Active account: true
          - Token scopes: 'gist', 'read:org', 'repo', 'workflow'
        """
        let parsed = EnvironmentDetector.parseGHAuthStatus(output)
        #expect(parsed.username == "boris-w")
        #expect(parsed.scopes.contains("repo"))
        #expect(!parsed.scopes.contains("notifications"))
    }

    @Test("Deduplicates PATH preserving priority order")
    func deduplicatesPATH() {
        let result = EnvironmentDetector.deduplicatePATH([
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "",
            "/usr/bin"
        ])
        #expect(result == "/opt/homebrew/bin:/usr/local/bin:/usr/bin")
    }

    @Test("Parses Lody workspaces and agent-configs JSON even with stdout transport preamble [REQ-014][ITER-009]")
    func parsesLodyCatalogOutputs() {
        let wsRaw = """
        [ws_123] Remote Streams transport attached
        {"ok":true,"workspaces":[{"id":"ws_123","name":"boris-w's workspace","slug":"boris-w"}]}
        """
        let workspaces = EnvironmentDetector.parseLodyWorkspacesOutput(wsRaw)
        #expect(workspaces.count == 1)
        #expect(workspaces[0].id == "ws_123")
        #expect(workspaces[0].slug == "boris-w")

        let agentsRaw = """
        [ws_123] Remote Streams transport attached
        {"ok":true,"workspaceId":"ws_123","items":[{"id":"cfg-agy","name":"Antigravity","agentType":"antigravity","runConfig":{"modes":[{"id":"plan","name":"Plan"}],"configOptions":[{"id":"thought_level","category":"thought_level","options":[{"value":"high","name":"High"}]}],"models":[{"id":"gemini-4-neon","name":"Gemini 4 Neon"},{"id":"claude-opus-5-5","name":"Claude Opus 5.5"}],"reasoningEffortValues":["low","medium","high","xhigh"]},"availability":{"state":"available"}}]}
        """
        let catalog = EnvironmentDetector.parseLodyAgentConfigsOutput(agentsRaw)
        #expect(catalog?.workspaceID == "ws_123")
        #expect(catalog?.agentConfigs.count == 1)
        let agy = catalog?.agentConfigs.first
        #expect(agy?.id == "cfg-agy")
        #expect(agy?.effortOptionKey == "thought_level")
        #expect(agy?.readOnlyModeID == "plan")
        #expect(agy?.models.count == 2)

        // 按旧别名 "antigravity" 匹配真实 Lody Agent 并解析模型列表
        let resolvedModels = LodyCatalogSnapshot.resolveModels(
            forAgentConfig: "antigravity",
            catalog: catalog,
            fallbackByEngine: [:]
        )
        #expect(resolvedModels.map(\.id) == ["default", "gemini-4-neon", "claude-opus-5-5"])

        let projectsRaw = """
        {
          "ok": true,
          "type": "local-project/list",
          "result": {
            "workspaces": [
              {
                "workspaceId": "ws_123",
                "projects": [
                  {
                    "localProjectId": "local-proj-1",
                    "name": "web",
                    "rootPath": "/tmp/nonexistent/web"
                  }
                ]
              }
            ]
          }
        }
        """
        let projects = EnvironmentDetector.parseLodyLocalProjectsOutput(projectsRaw)
        #expect(projects.count == 1)
        #expect(projects[0].id == "local-proj-1")
        #expect(projects[0].name == "web")

        let parsedURL = GitHubConnector.parsePullRequestReference("https://github.com/acme/web/pull/4790")
        #expect(parsedURL?.repository == "acme/web")
        #expect(parsedURL?.number == 4790)
        let parsedShort = GitHubConnector.parsePullRequestReference("boris-w/Lody#1")
        #expect(parsedShort?.repository == "boris-w/Lody")
        #expect(parsedShort?.number == 1)
    }
}
