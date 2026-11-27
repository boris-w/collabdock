import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：Lody 后台会话每一轮的耗时，从 CollabDock 派发这一轮（首轮 `session create` / 复审 `session chat`）算到会话最后一条消息。
///
/// 现状：耗时 = 会话最后一条消息时间 − **会话创建时间**，且超过 1 小时直接丢弃。
/// 续聊复审时会话创建时间是第 1 轮的开始时间 → 算出来几个小时 → 被丢弃，卡片上不显示耗时；即使不到 1 小时也会把第 1 轮与空闲时间算进去。
/// 首轮审查本身超过 1 小时也会丢失耗时。
@Suite("SPEC — per-round duration for Lody background sessions")
struct LodyRoundDurationSpecTests {
    static let sessionCreated = "2026-11-27T03:33:47.140Z"
    static let createdDate = isoWithFractions(sessionCreated)

    private func showOutput(lastMessageAt: Date, status: String = "idle", used: Int = 462_400) -> String {
        let ms = Int(lastMessageAt.timeIntervalSince1970 * 1000)
        return #"{"ok":true,"session":{"id":"sess-1","status":{"type":"\#(status)"},"createdAt":"\#(Self.sessionCreated)","lastMessageAt":\#(ms),"contextWindowUsage":{"used":\#(used)},"lastModel":{"modelId":"gemini-4-neon","name":"Gemini 4 Neon"}}}"#
    }

    @Test("The snapshot exposes when the session last produced a message")
    func exposesLastMessageAt() throws {
        let last = Self.createdDate.addingTimeInterval(2 * 3600 + 10 * 60)
        let snap = try #require(EnvironmentDetector.parseLodySessionShowOutput(showOutput(lastMessageAt: last)))
        let parsed = try #require(snap.lastMessageAt)
        #expect(abs(parsed.timeIntervalSince(last)) < 0.01)
    }

    @Test("SPEC: a continued round is timed from its own dispatch, not from session creation hours earlier")
    func continuedRoundDuration() throws {
        let dispatchedRoundTwo = Self.createdDate.addingTimeInterval(2 * 3600 + 1 * 60)
        let last = dispatchedRoundTwo.addingTimeInterval(9 * 60)
        let snap = try #require(EnvironmentDetector.parseLodySessionShowOutput(showOutput(lastMessageAt: last)))

        let duration = try #require(snap.roundDurationSeconds(since: dispatchedRoundTwo))
        #expect(duration == 9 * 60)
    }

    @Test("SPEC: a first round longer than an hour keeps its duration (no silent 1h cap)")
    func longFirstRoundKeepsDuration() throws {
        let last = Self.createdDate.addingTimeInterval(75 * 60)
        let snap = try #require(EnvironmentDetector.parseLodySessionShowOutput(showOutput(lastMessageAt: last)))

        let duration = try #require(snap.roundDurationSeconds(since: Self.createdDate))
        #expect(duration == 75 * 60)
    }

    @Test("No duration while the session has not answered since this round was dispatched")
    func noDurationBeforeAnswer() throws {
        let last = Self.createdDate.addingTimeInterval(12 * 60)            // 第 1 轮的最后一条消息
        let dispatchedRoundTwo = Self.createdDate.addingTimeInterval(2 * 3600)
        let snap = try #require(EnvironmentDetector.parseLodySessionShowOutput(showOutput(lastMessageAt: last, status: "running")))

        #expect(snap.roundDurationSeconds(since: dispatchedRoundTwo) == nil)
    }
}

private func isoWithFractions(_ value: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: value)!
}
