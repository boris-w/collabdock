import Foundation
import Testing
@testable import CollabDockCore

@Suite("Catalogs & defaults — Lody catalog cache, legacy decoding, project matching, Lody defaults")
struct CatalogAndDefaultsTests {
    private func tempSettingsStore() -> (SettingsStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collabdock-settings-\(UUID().uuidString)", isDirectory: true)
        return (SettingsStore(fileURL: dir.appendingPathComponent("settings.json")), dir)
    }

    private let catalog = LodyCatalogSnapshot(
        workspaceID: "ws_123",
        workspaces: [LodyWorkspaceOption(id: "ws_123", name: "Demo workspace", slug: "demo")],
        localProjects: [
            LodyLocalProjectOption(id: "lp-1", name: "backend", rootPath: "/Users/dev/code/backend", repositoryFullName: "acme/backend"),
            LodyLocalProjectOption(id: "lp-2", name: "web", rootPath: "/Users/dev/code/web")
        ],
        linkedGitHubRepos: ["acme/infra"],
        fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    @Test("The Lody catalog cache survives a save/load round trip next to settings.json")
    func lodyCatalogCacheRoundTrip() throws {
        let (store, dir) = tempSettingsStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(store.loadLodyCatalogCache() == nil)
        store.saveLodyCatalogCache(catalog)

        #expect(store.lodyCatalogCacheURL.deletingLastPathComponent() == store.fileURL.deletingLastPathComponent())
        #expect(store.loadLodyCatalogCache() == catalog)
    }

    @Test("A corrupted Lody catalog cache is ignored instead of crashing")
    func corruptedCatalogCache() throws {
        let (store, dir) = tempSettingsStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ not json".write(to: store.lodyCatalogCacheURL, atomically: true, encoding: .utf8)

        #expect(store.loadLodyCatalogCache() == nil)
    }

    @Test("A catalog cached by an older build (without projects / linked repos) still decodes")
    func legacyCatalogDecodes() throws {
        var dict = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? [String: Any])
        dict.removeValue(forKey: "localProjects")
        dict.removeValue(forKey: "linkedGitHubRepos")
        let legacy = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(LodyCatalogSnapshot.self, from: legacy)

        #expect(decoded.workspaceID == "ws_123")
        #expect(decoded.localProjects.isEmpty)
        #expect(decoded.linkedGitHubRepos.isEmpty)
    }

    @Test("Local project matching prefers the linked repository, then falls back to the folder name (case-insensitive)")
    func localProjectMatching() {
        #expect(catalog.matchLocalProject(forRepository: "ACME/Backend")?.id == "lp-1")
        #expect(catalog.matchLocalProject(forRepository: "acme/web")?.id == "lp-2", "no linked repo → match by project name")
        #expect(catalog.matchLocalProject(forRepository: "acme/unknown") == nil)
        #expect(catalog.matchLocalProject(forRepository: "  ") == nil)
        #expect(catalog.hasLinkedGitHubRepo("ACME/infra"))
        #expect(!catalog.hasLinkedGitHubRepo("acme/backend"))
    }

    @Test("Lody mode lists: the agent's own modes win, otherwise fall back by agent type, otherwise Lody defaults")
    func lodyModeResolution() {
        let withModes = LodyCatalogSnapshot(agentConfigs: [
            LodyAgentConfigOption(id: "cfg-1", name: "Custom", agentType: "claude", models: [], modes: [AgentModeOption(id: "plan", displayName: "Plan")])
        ])
        #expect(LodyCatalogSnapshot.resolveModes(forAgentConfig: "cfg-1", catalog: withModes).map(\.id) == ["plan"])
        #expect(LodyCatalogSnapshot.resolveModes(forAgentConfig: "default", catalog: withModes) == AgentEngine.lody.defaultModes)
        #expect(LodyCatalogSnapshot.resolveModes(forAgentConfig: "", catalog: nil) == AgentEngine.lody.defaultModes)
        #expect(!LodyCatalogSnapshot.resolveModes(forAgentConfig: "codex", catalog: nil).isEmpty)
    }

    @Test("The underlying engine of a Lody agent config is inferred from its type or name")
    func inferredUnderlyingEngine() {
        #expect(LodyAgentConfigOption(id: "a", name: "Claude Code", agentType: nil, models: []).inferredUnderlyingEngine == .claudeCode)
        #expect(LodyAgentConfigOption(id: "b", name: "x", agentType: "codex", models: []).inferredUnderlyingEngine == .codex)
        #expect(LodyAgentConfigOption(id: "c", name: "Antigravity", agentType: nil, models: []).inferredUnderlyingEngine == .antigravity)
        #expect(LodyAgentConfigOption(id: "d", name: "Mystery", agentType: "other", models: []).inferredUnderlyingEngine == nil)
    }

    @Test("Lody ships default model and mode options for the confirmation card")
    func lodyDefaults() {
        #expect(!AgentEngine.lody.defaultModels.isEmpty)
        #expect(!AgentEngine.lody.defaultModes.isEmpty)
    }
}
