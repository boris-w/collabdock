import Foundation
import SQLite3
import Testing
@testable import CollabDockCore

@Suite("Robustness — legacy data, restarts, and shell escaping")
struct RobustnessTests {
    private func tempPath(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-robust-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    @Test("CollaborationItem persisted by an older build (missing newer fields) still decodes with safe defaults")
    func legacyItemJSONDecodes() throws {
        let modern = Fixtures.prItem(repository: "acme/api", number: 42, verdict: "APPROVED")
        let data = try JSONEncoder().encode(modern)
        var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for newerKey in [
            "previousReview", "reviewRound", "remoteSessionStatus", "completionReason",
            "gitHubReviewVerdict", "sessionHandle", "executionOutput", "deliveryURL"
        ] {
            dict.removeValue(forKey: newerKey)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(CollaborationItem.self, from: legacyData)

        #expect(decoded.id == modern.id)
        #expect(decoded.reviewRound == 1)
        #expect(decoded.previousReview == nil)
        #expect(decoded.completionReason == nil)
        #expect(decoded.gitHubReviewVerdict == nil)
        #expect(decoded.payload == modern.payload)
    }

    @Test("Dedupe keys, cursors and items survive an app restart (new store instance on the same file)")
    func storeSurvivesRestart() async throws {
        let dbURL = tempPath("collabdock.sqlite")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let item = Fixtures.prItem(repository: "acme/api", number: 7)
        do {
            let store = try SQLiteTaskStore(databasePath: dbURL.path)
            try await store.markSeen(dedupeKey: "github:acme/api#7:sha1", itemID: item.id)
            try await store.upsertItem(item)
            try await store.saveCursor(SyncCursor(value: "Thu, 26 Nov 2026 10:00:00 GMT"), for: .github)
        }

        let reopened = try SQLiteTaskStore(databasePath: dbURL.path)
        #expect(try await reopened.hasSeen(dedupeKey: "github:acme/api#7:sha1"))
        #expect(try await reopened.hasSeen(dedupeKey: "github:acme/api#7:sha2") == false)
        #expect(try await reopened.loadCursor(for: .github)?.value == "Thu, 26 Nov 2026 10:00:00 GMT")
        #expect(try await reopened.loadAllItems().map(\.id) == [item.id])
    }

    @Test("A single corrupted row does not prevent the rest of the inbox from loading")
    func corruptedRowIsSkipped() async throws {
        let dbURL = tempPath("collabdock.sqlite")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let good = Fixtures.prItem(repository: "acme/api", number: 1)
        do {
            let store = try SQLiteTaskStore(databasePath: dbURL.path)
            try await store.upsertItem(good)
        }

        // 模拟旧版本/损坏数据：直接写入一行无法解码的 payload
        var db: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        let sql = """
        INSERT INTO collaboration_items (id, platform, status, updated_at, payload_json)
        VALUES ('broken', 'github', 'pendingConfirmation', 9999999999, '{"not":"an item"}');
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let reopened = try SQLiteTaskStore(databasePath: dbURL.path)
        #expect(try await reopened.loadAllItems().map(\.id) == [good.id])
    }

    @Test("Security: resume shell command quotes hostile session IDs and paths so nothing is injected")
    func resumeShellCommandIsInjectionSafe() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("collabdock-shell-\(UUID().uuidString)", isDirectory: true)
        let workspace = sandbox.appendingPathComponent(#"it's a "repo" $(touch pwned-dir)"#, isDirectory: true)
        let bin = sandbox.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // 假 claude：把收到的参数逐行写到文件
        let argsFile = sandbox.appendingPathComponent("args.txt")
        let fakeClaude = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done > \"\(argsFile.path)\"\n"
            .write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let pwnedMarker = sandbox.appendingPathComponent("pwned")
        let hostileID = "abc'; touch '\(pwnedMarker.path)'; echo '"
        let handle = AgentSessionHandle(
            engine: .claudeCode,
            sessionID: hostileID,
            workspacePath: workspace.path,
            launchMode: .managedStructuredRun
        )
        let command = DirectCLIBackend().resumeShellCommand(for: handle)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
        process.currentDirectoryURL = sandbox
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let recorded = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(recorded == "--resume\n\(hostileID)\n")
        #expect(!FileManager.default.fileExists(atPath: pwnedMarker.path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("pwned-dir").path))
    }
}
