import Foundation
import Testing
@testable import CollabDockCore

/// Lody CLI `--json` 输出解析（直连 Claude / agy 的 stream-json 与结构化审查 JSON 解析随直连引擎一起移除）
@Suite("AgentStreamParser — Lody JSON output [REQ-007][TASK-012]")
struct AgentStreamParserTests {
    @Test("Extracts the Lody session id from both `session create` and `session chat` JSON shapes")
    func parsesLodySessionIDs() {
        #expect(AgentStreamParser.parseLine(#"{"session":{"id":"ses_lody_99"}}"#).sessionID == "ses_lody_99")
        #expect(AgentStreamParser.parseLine(#"{"ok":true,"sessionId":"lody-sess-1","status":"running"}"#).sessionID == "lody-sess-1")
    }

    @Test("Blank lines are ignored and non-JSON lines become a short progress hint")
    func plainLines() {
        let blank = AgentStreamParser.parseLine("   ")
        #expect(blank.sessionID == nil)
        #expect(blank.progressHint == nil)

        let plain = AgentStreamParser.parseLine("Resolving local project…")
        #expect(plain.sessionID == nil)
        #expect(plain.progressHint == "Resolving local project…")
    }
}
