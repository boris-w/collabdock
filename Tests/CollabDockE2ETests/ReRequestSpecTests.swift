import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（修复前为红）：真实场景回放 ——
/// 1. 作者请我 review（第 1 轮），我针对提交 S 提交了 Request Changes；
/// 2. 作者**没有推新提交**，在评论区只写了 `@me`，随后点了 Re-request review；
/// 3. 我的 GitHub 通知接口返回 200 但列表为空（通知只走邮件等情况），CollabDock 只能靠 Search 兜底发现事件。
///
/// 期望：收件箱出现第 2 轮复审卡片（且只出现一次），@ 提及也能被 Search 兜底找到。
@Suite("E2E SPEC — re-request on the same commit, @mentions without notifications", .serialized)
struct ReRequestSpecTests {
    static let repo = "acme/backend"
    static let number = 7
    static let sha = "abcdef0123456789abcdef0123456789abcdef01"
    static let firstRequest = "2026-11-27T02:29:16Z"
    static let myReview = "2026-11-27T03:50:48Z"
    static let mention = "2026-11-27T05:16:30Z"
    static let reRequest = "2026-11-27T05:37:16Z"

    static var roundOneKey: String { "github:\(repo)#\(number):reviewRequested:\(sha)" }

    static func roundOneItem() -> CollaborationItem {
        CollaborationItem(
            id: roundOneKey,
            platform: .github,
            itemKind: .pullRequest,
            scope: repo,
            externalRef: "#\(number)",
            title: "feat: cursor pagination",
            url: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
            author: "carol",
            triggeredBy: "carol",
            triggerKind: .reviewRequested,
            payload: .codeChange(CodeChangePayload(
                repository: repo, number: number, baseRef: "develop", headRef: "feat/pagination",
                headSHA: sha, additions: 100, deletions: 20, changedFiles: 5
            )),
            createdAt: ISO8601DateFormatter().date(from: firstRequest)!,
            status: .draftReady,
            sessionHandle: AgentSessionHandle(engine: .codex, sessionID: "0199c3a2-7b1e-7f30-9a4d-5e2f8c61d0b7", workspacePath: "/tmp/wt", launchMode: .managedStructuredRun),
            gitHubReviewVerdict: "CHANGES_REQUESTED"
        )
    }

    static func timeline(extra: [String] = []) -> String {
        let events = [
            #"{"event":"review_requested","created_at":"\#(firstRequest)","actor":{"login":"carol"},"requested_reviewer":{"login":"me"}}"#,
            #"{"event":"reviewed","submitted_at":"\#(myReview)","state":"changes_requested","user":{"login":"me"},"commit_id":"\#(sha)"}"#,
            #"{"event":"commented","id":900,"created_at":"\#(mention)","user":{"login":"carol"},"body":"@me "}"#,
            #"{"event":"review_requested","created_at":"\#(reRequest)","actor":{"login":"carol"},"requested_reviewer":{"login":"me"}}"#
        ] + extra
        return "[" + events.joined(separator: ",") + "]"
    }

    static func github(updatedAt: String = reRequest, timeline: String = timeline()) -> FakeGitHub {
        let gh = FakeGitHub()
        // 通知接口正常（200），但没有任何通知
        gh.on("GET", "/notifications", json: "[]", headers: ["Last-Modified": "Thu, 27 Nov 2026 05:40:00 GMT", "X-Poll-Interval": "60"])
        let searchItem = """
        {"items":[{"number":\(number),"title":"feat: cursor pagination","body":"",
          "updated_at":"\(updatedAt)",
          "repository_url":"https://api.github.com/repos/\(repo)",
          "comments_url":"https://api.github.com/repos/\(repo)/issues/\(number)/comments",
          "pull_request":{"url":"https://api.github.com/repos/\(repo)/pulls/\(number)"}}]}
        """
        gh.on("GET", "/search/issues", json: searchItem)
        gh.on("GET", "/repos/\(repo)/pulls/\(number)", json: """
        {"number":\(number),"title":"feat: cursor pagination","html_url":"https://github.com/\(repo)/pull/\(number)",
         "draft":false,"additions":100,"deletions":20,"changed_files":5,"updated_at":"\(updatedAt)",
         "user":{"login":"carol"},"requested_reviewers":[{"login":"me"}],
         "base":{"ref":"develop","sha":"b0"},"head":{"ref":"feat/pagination","sha":"\(sha)"}}
        """)
        gh.on("GET", "/repos/\(repo)/issues/\(number)/timeline", json: timeline)
        gh.on("GET", "/repos/\(repo)/issues/\(number)/comments", json: #"[{"id":900,"body":"@me ","user":{"login":"carol"},"created_at":"\#(mention)"}]"#)
        return gh
    }

    private func connector(_ gh: FakeGitHub) -> GitHubConnector {
        GitHubConnector(transport: gh, tokenProvider: StaticTokenProvider(token: "gho_placeholder"))
    }

    private func tempStore() throws -> (SQLiteTaskStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collabdock-rerequest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try SQLiteTaskStore(databasePath: dir.appendingPathComponent("db.sqlite").path), dir)
    }

    @Test("SPEC: a re-request on the same commit after my review creates a round-2 inbox item, exactly once")
    func reRequestOnSameCommitCreatesNewRound() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let roundOne = Self.roundOneItem()
        try await store.markSeen(dedupeKey: Self.roundOneKey, itemID: roundOne.id)
        try await store.upsertItem(roundOne)
        let gh = Self.github()

        let first = try await InboxSyncService(source: connector(gh), store: store).sync(
            InboxSyncRequest(existingItems: [roundOne], currentHandle: "me")
        )

        let roundTwo = try #require(
            first.newItems.first { $0.scope == Self.repo && $0.externalRef == "#\(Self.number)" },
            "the re-request was swallowed: same head SHA produced the same dedupe key as round 1"
        )
        #expect(roundTwo.id != roundOne.id)
        #expect(roundTwo.triggerKind == .reviewRequested)
        #expect(roundTwo.reviewRound == 2)
        #expect(roundTwo.previousReview?.previousItemID == roundOne.id)
        #expect(roundTwo.previousReview?.reviewedHeadSHA == Self.sha)
        #expect(first.notifications.contains(.incomingTask(roundTwo)))

        // App 重启后再次同步（全新的同步状态、没有指纹缓存）：同一次 re-request 不能再产生新卡片
        let again = try await InboxSyncService(source: connector(Self.github()), store: store).sync(
            InboxSyncRequest(existingItems: [roundOne, roundTwo], currentHandle: "me")
        )
        #expect(again.newItems.filter { $0.externalRef == "#\(Self.number)" }.isEmpty, "the same re-request must not notify twice")
    }

    @Test("SPEC: a review request sent to someone else later does not create a new round for me")
    func requestToSomeoneElseIsIgnored() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let roundOne = Self.roundOneItem()
        try await store.markSeen(dedupeKey: Self.roundOneKey, itemID: roundOne.id)

        let first = try await InboxSyncService(source: connector(Self.github()), store: store).sync(
            InboxSyncRequest(existingItems: [roundOne], currentHandle: "me")
        )
        let roundTwo = try #require(first.newItems.first { $0.externalRef == "#\(Self.number)" })

        let laterOther = #"{"event":"review_requested","created_at":"2026-11-27T06:10:00Z","actor":{"login":"carol"},"requested_reviewer":{"login":"dave"}}"#
        let gh = Self.github(updatedAt: "2026-11-27T06:10:00Z", timeline: Self.timeline(extra: [laterOther]))
        let after = try await InboxSyncService(source: connector(gh), store: store).sync(
            InboxSyncRequest(existingItems: [roundOne, roundTwo], currentHandle: "me")
        )
        #expect(after.newItems.filter { $0.externalRef == "#\(Self.number)" }.isEmpty)
    }

    @Test("Upgrade safety: an outstanding first request already in the inbox (old head-SHA key) is not announced again")
    func firstRequestKeepsItsKey() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        var pending = Self.roundOneItem()
        pending.status = .pendingConfirmation
        pending.gitHubReviewVerdict = nil
        try await store.markSeen(dedupeKey: Self.roundOneKey, itemID: pending.id)
        let onlyFirstRequest = "[" + #"{"event":"review_requested","created_at":"\#(Self.firstRequest)","actor":{"login":"carol"},"requested_reviewer":{"login":"me"}}"# + "]"

        let result = try await InboxSyncService(source: connector(Self.github(updatedAt: Self.firstRequest, timeline: onlyFirstRequest)), store: store).sync(
            InboxSyncRequest(existingItems: [pending], currentHandle: "me")
        )

        #expect(result.newItems.isEmpty, "a request I have not reviewed yet keeps the head-SHA key and is not re-announced")
    }

    @Test("SPEC: @mentions are found through Search even when the notifications API returns nothing")
    func mentionsFoundWithoutNotifications() async throws {
        let gh = Self.github()

        let batch = try await connector(gh).poll(PollRequest(cursor: nil, reconcileNow: true, knownFingerprints: [:]))

        #expect(gh.requests("GET", "/search/issues").contains { $0.query.contains("mentions:@me") },
                "mentions:@me must be searched on the reconcile cadence, not only after a 403")
        let mention = try #require(batch.candidates.first { $0.event.triggerKind == .mention })
        #expect(mention.item.externalRef == "#\(Self.number)")
        #expect(mention.event.actor == "carol")
        #expect(mention.item.triggerBody?.contains("@me") == true)
    }
}
