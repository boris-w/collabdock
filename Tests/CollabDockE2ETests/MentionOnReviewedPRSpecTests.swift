import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：@ 提及事件要带上「我是不是这个 PR 的 reviewer」。
/// 真实时刻回放（复用 ReRequestSpecTests 的场景数据）：我 03:50 提交 Request Changes 后被 GitHub 移出 requested_reviewers，
/// 作者 05:16 在评论里只写了 `@me`。这一条应该进收件箱，同时把我已处理过的第 1 轮卡片归档为「已进入下一轮」。
@Suite("E2E SPEC — bare @mention on a PR I already reviewed", .serialized)
struct MentionOnReviewedPRSpecTests {
    typealias S = ReRequestSpecTests

    /// 只有首次请求、我的 review 和作者的 @，没有再次请求；我已不在 requested_reviewers 里
    static let timelineBeforeReRequest = "[" + [
        #"{"event":"review_requested","created_at":"\#(S.firstRequest)","actor":{"login":"carol"},"requested_reviewer":{"login":"me"}}"#,
        #"{"event":"reviewed","submitted_at":"\#(S.myReview)","state":"changes_requested","user":{"login":"me"},"commit_id":"\#(S.sha)"}"#,
        #"{"event":"commented","id":900,"created_at":"\#(S.mention)","user":{"login":"carol"},"body":"@me "}"#
    ].joined(separator: ",") + "]"

    static func github(requestedReviewers: [String], timeline: String = timelineBeforeReRequest) -> FakeGitHub {
        let gh = S.github(updatedAt: S.mention, timeline: timeline)
        let reviewers = requestedReviewers.map { #"{"login":"\#($0)"}"# }.joined(separator: ",")
        gh.on("GET", "/repos/\(S.repo)/pulls/\(S.number)", json: """
        {"number":\(S.number),"title":"feat: cursor pagination","html_url":"https://github.com/\(S.repo)/pull/\(S.number)",
         "draft":false,"additions":100,"deletions":20,"changed_files":5,"updated_at":"\(S.mention)",
         "user":{"login":"carol"},"requested_reviewers":[\(reviewers)],
         "base":{"ref":"develop","sha":"b0"},"head":{"ref":"feat/pagination","sha":"\(S.sha)"}}
        """)
        return gh
    }

    private func mentionCandidate(_ gh: FakeGitHub, viewer: String?) async throws -> PolledCollaborationCandidate? {
        let connector = GitHubConnector(transport: gh, tokenProvider: StaticTokenProvider(token: "gho_placeholder"))
        let batch = try await connector.poll(PollRequest(reconcileNow: true, viewerLogin: viewer))
        return batch.candidates.first { $0.event.triggerKind == .mention }
    }

    @Test("SPEC: requested reviewer → the mention is flagged as on a PR I review")
    func requestedReviewerIsFlagged() async throws {
        let mention = try #require(try await mentionCandidate(Self.github(requestedReviewers: ["me"]), viewer: "me"))
        #expect(mention.event.viewerIsReviewer)
    }

    @Test("SPEC: already reviewed (no longer requested) → still flagged")
    func pastReviewerIsFlagged() async throws {
        let mention = try #require(try await mentionCandidate(Self.github(requestedReviewers: []), viewer: "me"))
        #expect(mention.event.viewerIsReviewer)
    }

    @Test("Not requested and never reviewed, or viewer unknown → not flagged (keyword rule applies)")
    func strangersAreNotFlagged() async throws {
        let othersOnly = "[" + #"{"event":"review_requested","created_at":"\#(S.firstRequest)","actor":{"login":"carol"},"requested_reviewer":{"login":"dave"}}"# + "]"
        let notMine = try #require(try await mentionCandidate(Self.github(requestedReviewers: ["dave"], timeline: othersOnly), viewer: "me"))
        #expect(notMine.event.viewerIsReviewer == false)

        let unknownViewer = try #require(try await mentionCandidate(Self.github(requestedReviewers: ["me"]), viewer: nil))
        #expect(unknownViewer.event.viewerIsReviewer == false)
    }

    @Test("SPEC: end to end — the bare @me after my review becomes the next round and archives my round-1 card")
    func bareMentionAfterReviewStartsNextRound() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collabdock-mention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteTaskStore(databasePath: dir.appendingPathComponent("db.sqlite").path)
        let roundOne = S.roundOneItem()
        try await store.markSeen(dedupeKey: S.roundOneKey, itemID: roundOne.id)
        try await store.upsertItem(roundOne)
        let connector = GitHubConnector(transport: Self.github(requestedReviewers: []), tokenProvider: StaticTokenProvider(token: "gho_placeholder"))

        let result = try await InboxSyncService(source: connector, store: store).sync(
            InboxSyncRequest(existingItems: [roundOne], currentHandle: "me")
        )

        let card = try #require(result.newItems.first { $0.externalRef == "#\(S.number)" }, "the bare @me was dropped by the keyword rule")
        #expect(result.newItems.filter { $0.externalRef == "#\(S.number)" }.count == 1)
        #expect(card.triggerKind == .mention)
        #expect(card.reviewRound == 2)
        #expect(card.previousReview?.previousItemID == roundOne.id)
        #expect(result.notifications.count == 1)
        #expect(result.supersededItems.map(\.id) == [roundOne.id])
        #expect(try await store.loadAllItems().first { $0.id == roundOne.id }?.completionReason == .superseded)
    }
}
