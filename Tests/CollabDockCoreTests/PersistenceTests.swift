import Foundation
import Testing
@testable import CollabDockCore

@Suite("SQLiteTaskStore & SettingsStore Tests [REQ-002][REQ-011][TASK-006][TASK-007]")
struct PersistenceTests {
    @Test("Persists items, status updates, deduplication keys, and sync cursors in SQLite")
    func sqlitePersistenceRoundTrip() async throws {
        let store = try SQLiteTaskStore(databasePath: ":memory:")

        var item = CollaborationItem(
            id: "gh:acme/backend#42",
            platform: .github,
            itemKind: .pullRequest,
            scope: "acme/backend",
            externalRef: "#42",
            title: "feat: sqlite store",
            url: URL(string: "https://github.com/acme/backend/pull/42")!,
            author: "alice",
            triggeredBy: "alice",
            triggerKind: .reviewRequested,
            payload: .codeChange(
                CodeChangePayload(
                    repository: "acme/backend",
                    number: 42,
                    baseRef: "main",
                    headRef: "feat/sqlite",
                    headSHA: "abc123",
                    additions: 50,
                    deletions: 10,
                    changedFiles: 2
                )
            )
        )

        #expect(try await store.hasSeen(dedupeKey: "key-1") == false)
        try await store.markSeen(dedupeKey: "key-1", itemID: item.id)
        #expect(try await store.hasSeen(dedupeKey: "key-1") == true)

        try await store.upsertItem(item)
        var loaded = try await store.loadAllItems()
        #expect(loaded.count == 1)
        #expect(loaded.first?.status == .pendingConfirmation)

        item.status = .dismissed
        try await store.upsertItem(item)
        loaded = try await store.loadAllItems()
        #expect(loaded.first?.status == .dismissed)

        let cursor = SyncCursor(value: "Thu, 26 Nov 2026 10:00:00 GMT")
        try await store.saveCursor(cursor, for: .github)
        let loadedCursor = try await store.loadCursor(for: .github)
        #expect(loadedCursor?.value == cursor.value)
    }

    @Test("Persists AppSettings and merges TeamPreset without overwriting personal preferences")
    func settingsAndTeamPresetMerge() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-test-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let store = SettingsStore(fileURL: tempURL)
        var personal = AppSettings(
            defaultEngine: .antigravity,
            defaultModels: [.antigravity: "gemini-4-neon-xhigh"],
            workspaceSearchRoots: ["~/my-private-code"]
        )
        try store.save(personal)

        let reloaded = store.load()
        #expect(reloaded.defaultEngine == .antigravity)
        #expect(reloaded.workspaceSearchRoots == ["~/my-private-code"])

        var teamSource = AppSettings()
        teamSource.globalTriggerRules.scopeAllowlist = ["acme/*"]
        teamSource.globalTriggerRules.mentionKeywords = ["cr", "audit"]
        let presetData = try store.exportTeamPresetData(teamName: "Acme Eng", from: teamSource)
        let decoded = try store.decodeTeamPreset(from: presetData)

        personal.applyTeamPreset(decoded)
        #expect(personal.globalTriggerRules.scopeAllowlist == ["acme/*"])
        #expect(personal.globalTriggerRules.mentionKeywords == ["cr", "audit"])
        // 个人模型和本地代码目录不受团队配置包覆盖
        #expect(personal.defaultEngine == .antigravity)
        #expect(personal.workspaceSearchRoots == ["~/my-private-code"])
    }

    @Test("Backward-compatibly decodes legacy settings.json missing newer fields and migrates legacy Lody agent placeholder")
    func decodesLegacySettingsJSON() throws {
        let legacyJSON = """
        {
          "pollIntervalSeconds": 120,
          "defaultEngine": "lody",
          "defaultModels": {
            "lody": "antigravity",
            "claude": "opus"
          },
          "workspaceSearchRoots": ["~/custom-code"]
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.pollIntervalSeconds == 120)
        #expect(decoded.defaultEngine == .lody)
        #expect(decoded.workspaceSearchRoots == ["~/custom-code"])
        #expect(decoded.injectPresetPrompt == true)
        #expect(decoded.lodyConfig.preferNPXFallback == true)
        #expect(decoded.lodyConfig.defaultAgentConfig == "antigravity")
        #expect(decoded.defaultModels[.lody] == "default")
        #expect(decoded.presets == TaskPreset.defaults)
        #expect(decoded.presets.count == 1)

        // 验证未修改过的旧版 6 条出厂预制自动精简为 1 条极简默认，而用户改过的自定义模板完整保留
        var oldUnmodified = AppSettings()
        oldUnmodified.presets = TaskPreset.legacyFactoryDefaults
        let oldData = try JSONEncoder().encode(oldUnmodified)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: oldData)
        #expect(migrated.presets.count == 1)
        #expect(migrated.presets.first?.name == "Review 这个 PR")

        var customUser = AppSettings()
        customUser.presets = [TaskPreset(id: "mine", name: "我的模板", category: .codeReview, promptInstructions: "只看并发")]
        let customData = try JSONEncoder().encode(customUser)
        let preserved = try JSONDecoder().decode(AppSettings.self, from: customData)
        #expect(preserved.presets.count == 1)
        #expect(preserved.presets.first?.id == "mine")

        var withRepoOverride = AppSettings()
        withRepoOverride.repositoryDirectoryOverrides["acme/web"] = "/Users/dev/code/web"
        withRepoOverride.developerModeEnabled = true
        let overrideData = try JSONEncoder().encode(withRepoOverride)
        let decodedOverride = try JSONDecoder().decode(AppSettings.self, from: overrideData)
        #expect(decodedOverride.repositoryDirectoryOverrides["acme/web"] == "/Users/dev/code/web")
        #expect(decodedOverride.developerModeEnabled == true)
        #expect(decoded.developerModeEnabled == false)
    }

    @Test("Mailbox status semantics keep drafts/failures in inbox and delete preserves usage ledger [ITER-015]")
    func mailboxStatusAndDeletePreserveUsageLedger() async throws {
        // 邮件式分栏语义
        #expect(CollaborationTaskStatus.pendingConfirmation.isInboxActive == true)
        #expect(CollaborationTaskStatus.running.isInboxActive == true)
        #expect(CollaborationTaskStatus.draftReady.isInboxActive == true)
        #expect(CollaborationTaskStatus.failed.isInboxActive == true)
        #expect(CollaborationTaskStatus.completed.isInboxActive == false)
        #expect(CollaborationTaskStatus.dismissed.isInboxActive == false)

        // 删除列表条目不应删掉 review_usage_runs 用量账本与 seen_events 去重记录
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-mailbox-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempDB) }

        let store = try SQLiteTaskStore(databasePath: tempDB.path)
        let item = CollaborationItem(
            id: "gh-item-99",
            platform: .github,
            itemKind: .pullRequest,
            scope: "acme/web",
            externalRef: "#4800",
            title: "fix: moderation",
            url: URL(string: "https://github.com/acme/web/pull/4800")!,
            author: "dev",
            triggeredBy: "dev",
            triggerKind: .reviewRequested,
            payload: .codeChange(
                CodeChangePayload(repository: "acme/web", number: 4800, baseRef: "develop", headRef: "fix/m", headSHA: "abc123", additions: 10, deletions: 2, changedFiles: 1)
            ),
            status: .completed
        )
        try await store.upsertItem(item)
        try await store.markSeen(dedupeKey: "k-4800", itemID: item.id)

        let usageRun = ReviewUsageRun(
            id: "run-99",
            itemID: item.id,
            platform: .github,
            scope: item.scope,
            externalRef: item.externalRef,
            title: item.title,
            engine: .lody,
            model: "Gemini 4 Neon",
            effort: .high,
            usage: AgentUsageMetrics(totalTokens: 50_000, durationSeconds: 20, metricKind: .contextWindow)
        )
        try await store.upsertUsageRun(usageRun)

        try await store.deleteItem(id: item.id)

        let remainingItems = try await store.loadAllItems()
        let remainingUsage = try await store.loadAllUsageRuns()
        let stillSeen = try await store.hasSeen(dedupeKey: "k-4800")
        #expect(remainingItems.isEmpty)
        #expect(remainingUsage.count == 1)
        #expect(remainingUsage.first?.id == "run-99")
        #expect(stillSeen == true)
    }
}
