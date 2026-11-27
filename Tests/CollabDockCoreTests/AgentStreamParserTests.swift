import Foundation
import Testing
@testable import CollabDockCore

@Suite("AgentStreamParser Tests [REQ-007][TASK-012]")
struct AgentStreamParserTests {
    @Test("Extracts session ID, tool progress, and structured output from Claude/Agy/Lody JSON lines")
    func parsesStreamingEvents() {
        let claudeInit = #"{"type":"system","session_id":"sess_claude_01"}"#
        let p1 = AgentStreamParser.parseLine(claudeInit)
        #expect(p1.sessionID == "sess_claude_01")
        #expect(p1.progressHint?.contains("初始化") == true)

        let claudeTool = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/Sources/Auth.swift"}}]}}"#
        let p2 = AgentStreamParser.parseLine(claudeTool)
        #expect(p2.progressHint == "正在 Read：Auth.swift")

        let lodyResp = #"{"session":{"id":"ses_lody_99"}}"#
        let p3 = AgentStreamParser.parseLine(lodyResp)
        #expect(p3.sessionID == "ses_lody_99")

        let bgPlain = "Started background session id: bg_42abc9"
        let p4 = AgentStreamParser.parseLine(bgPlain)
        #expect(p4.sessionID == "bg_42abc9")

        // Antigravity (agy) 嵌套 result 与 step_update 事件解析
        let agyTool = #"{"event":"step_update","step_update":{"conversation_id":"conv_agy_1","step_type":"tool","tool_name":"view_file","tool_info":{"parameters":{"Path":"/repo/src/cli.ts"}}}}"#
        let p5 = AgentStreamParser.parseLine(agyTool)
        #expect(p5.sessionID == "conv_agy_1")
        #expect(p5.progressHint == "正在 view_file：cli.ts")

        let agyResult = #"{"event":"result","result":{"conversation_id":"conv_agy_1","status":"SUCCESS","response":"{\"summary\":\"ok\",\"recommendedVerdict\":\"APPROVE\",\"comments\":[]}"}}"#
        let p6 = AgentStreamParser.parseLine(agyResult)
        #expect(p6.sessionID == "conv_agy_1")
        #expect(p6.finalText?.contains("\"recommendedVerdict\":\"APPROVE\"") == true)
    }

    @Test("Decodes fenced markdown JSON into CodeReviewResult gracefully")
    func decodesFencedCodeReviewJSON() {
        let wrapped = """
        Here is the structured review:
        ```json
        {
          "summary": "发现 1 处边界问题",
          "recommendedVerdict": "REQUEST_CHANGES",
          "comments": [
            {
              "path": "Sources/Auth.swift",
              "line": 42,
              "side": "RIGHT",
              "severity": "critical",
              "title": "缺少空值保护",
              "body": "claims 可能为 nil",
              "suggestion": "guard let claims else { return }"
            }
          ]
        }
        ```
        """

        let prItem = CollaborationItem(
            id: "pr-1",
            platform: .github,
            itemKind: .pullRequest,
            scope: "acme/backend",
            externalRef: "#1",
            title: "test",
            url: URL(string: "https://github.com/acme/backend/pull/1")!,
            author: "a",
            triggeredBy: "a",
            triggerKind: .mention,
            payload: .codeChange(
                CodeChangePayload(repository: "acme/backend", number: 1, baseRef: "main", headRef: "feat", headSHA: "abc", additions: 5, deletions: 1, changedFiles: 1)
            )
        )

        let decoded = AgentStreamParser.decodeExecutionOutput(from: wrapped, for: prItem)
        guard case .codeReview(let review) = decoded else {
            Issue.record("Expected .codeReview")
            return
        }
        #expect(review.recommendedVerdict == .requestChanges)
        #expect(review.comments.count == 1)
        #expect(review.comments.first?.suggestion == "guard let claims else { return }")
    }
}
