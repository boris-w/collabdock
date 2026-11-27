import Foundation

/// 配置持久化与团队配置包导入导出服务（关联 REQ-003, REQ-011, TASK-007）
public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = appSupport
                .appendingPathComponent("CollabDock", isDirectory: true)
                .appendingPathComponent("settings.json")
        }
    }

    public func load() -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return AppSettings()
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func save(_ settings: AppSettings) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func exportTeamPresetData(teamName: String, from settings: AppSettings) throws -> Data {
        let preset = TeamPreset(
            teamName: teamName,
            scopeAllowlist: settings.globalTriggerRules.scopeAllowlist,
            mentionKeywords: settings.globalTriggerRules.mentionKeywords,
            taskPresets: settings.presets
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(preset)
    }

    public var lodyCatalogCacheURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("lody-catalog-cache.json")
    }

    public func loadLodyCatalogCache() -> LodyCatalogSnapshot? {
        guard FileManager.default.fileExists(atPath: lodyCatalogCacheURL.path),
              let data = try? Data(contentsOf: lodyCatalogCacheURL) else {
            return nil
        }
        return try? JSONDecoder().decode(LodyCatalogSnapshot.self, from: data)
    }

    public func saveLodyCatalogCache(_ snapshot: LodyCatalogSnapshot) {
        let dir = lodyCatalogCacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: lodyCatalogCacheURL, options: [.atomic])
        }
    }

    public func decodeTeamPreset(from data: Data) throws -> TeamPreset {
        try JSONDecoder().decode(TeamPreset.self, from: data)
    }
}
