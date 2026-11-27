import Foundation
import Testing
@testable import CollabDockCore

@Suite("PR Auto-Completion & GraphQL Batch Sync Tests")
struct PRAutoCompletionTests {
    private func makePRItem(
        headSHA: String = "abcdef0123456789abcdef0123456789abcdef01",
        createdAt: Date = Date()
    ) -> CollaborationItem {
        CollaborationItem(
            id: "github:acme/web#4800:reviewRequested:\(headSHA)",
            platform: .github,
            itemKind: .pullRequest,
            scope: "acme/web",
            externalRef: "#4800",
            title: "fix(chat): moderation follow-ups",
            url: URL(string: "https://github.com/acme/web/pull/4800")!,
            author: "carol",
            triggeredBy: "carol",
            triggerKind: .reviewRequested,
            payload: .codeChange(
                CodeChangePayload(
                    repository: "acme/web",
                    number: 4800,
                    baseRef: "develop",
                    headRef: "fix/chat-moderation-followups",
                    headSHA: headSHA,
                    additions: 100,
                    deletions: 20,
                    changedFiles: 5
                )
            ),
            createdAt: createdAt,
            status: .draftReady
        )
    }

    @Test("Parses real GitHub GraphQL batch PR review payload and keeps CHANGES_REQUESTED in inbox [ITER-017]")
    func parsesGraphQLAndKeepsChangesRequested() throws {
        let json = """
        {
          "data": {
            "viewer": { "login": "boris-w" },
            "pr0": {
              "pullRequest": {
                "state": "OPEN",
                "merged": false,
                "headRefOid": "abcdef0123456789abcdef0123456789abcdef01",
                "reviews": {
                  "nodes": [
                    {
                      "state": "CHANGES_REQUESTED",
                      "submittedAt": "2026-11-27T03:50:48Z",
                      "author": { "login": "boris-w" },
                      "commit": { "oid": "abcdef0123456789abcdef0123456789abcdef01" }
                    }
                  ]
                }
              }
            }
          }
        }
        """
        let parsed = GitHubConnector.parseGraphQLPRStatusResponse(
            data: Data(json.utf8),
            targets: [(key: "acme/web#4800", repository: "acme/web", number: 4800)]
        )
        #expect(parsed.viewerLogin == "boris-w")
        let snap = try #require(parsed.snapshots["acme/web#4800"])
        #expect(snap.state == "OPEN")
        #expect(snap.merged == false)
        #expect(snap.reviews.count == 1)

        let eval = GitHubConnector.evaluatePRAutoCompletion(
            item: makePRItem(),
            snapshot: snap,
            viewerLogin: "boris-w"
        )
        // Request Changes 不自动进入已完成，但标记为 CHANGES_REQUESTED 提示待作者修复
        #expect(eval.completionReason == nil)
        #expect(eval.latestViewerVerdict == "CHANGES_REQUESTED")
    }

    @Test("Auto-completes on APPROVED, MERGED, and CLOSED while protecting multi-round re-reviews and dismissed approvals [ITER-017]")
    func evaluatesApprovalMergeCloseAndEdgeCases() {
        let now = Date()
        let oldDate = now.addingTimeInterval(-3600)
        let newDate = now.addingTimeInterval(30)

        // 1. 当前轮次 Approved -> 自动归档为 .prApproved
        let approvedSnap = GitHubConnector.PRRemoteStatusSnapshot(
            repository: "acme/web",
            number: 4800,
            state: "OPEN",
            merged: false,
            headRefOID: "sha_r1",
            reviews: [
                .init(state: "CHANGES_REQUESTED", authorLogin: "boris-w", submittedAt: oldDate, commitOID: "sha_r0"),
                .init(state: "APPROVED", authorLogin: "Boris-W", submittedAt: newDate, commitOID: "sha_r1"),
                .init(state: "COMMENTED", authorLogin: "boris-w", submittedAt: newDate.addingTimeInterval(5), commitOID: "sha_r1")
            ]
        )
        let evalApproved = GitHubConnector.evaluatePRAutoCompletion(
            item: makePRItem(headSHA: "sha_r1", createdAt: now),
            snapshot: approvedSnap,
            viewerLogin: "boris-w"
        )
        #expect(evalApproved.completionReason == .prApproved)

        // 2. 第 1 轮旧 Approved 不得误杀刚进来的第 2 轮新 commit 复审
        let round2Snap = GitHubConnector.PRRemoteStatusSnapshot(
            repository: "acme/web",
            number: 4800,
            state: "OPEN",
            merged: false,
            headRefOID: "sha_r2",
            reviews: [
                .init(state: "APPROVED", authorLogin: "boris-w", submittedAt: oldDate, commitOID: "sha_r1")
            ]
        )
        let evalRound2 = GitHubConnector.evaluatePRAutoCompletion(
            item: makePRItem(headSHA: "sha_r2", createdAt: now),
            snapshot: round2Snap,
            viewerLogin: "boris-w"
        )
        #expect(evalRound2.completionReason == nil)

        // 3. Pending 草稿不触发完成
        let pendingSnap = GitHubConnector.PRRemoteStatusSnapshot(
            repository: "acme/web",
            number: 4800,
            state: "OPEN",
            merged: false,
            headRefOID: "sha_r1",
            reviews: [
                .init(state: "PENDING", authorLogin: "boris-w", submittedAt: nil, commitOID: "sha_r1")
            ]
        )
        #expect(GitHubConnector.evaluatePRAutoCompletion(item: makePRItem(headSHA: "sha_r1", createdAt: now), snapshot: pendingSnap, viewerLogin: "boris-w").completionReason == nil)

        // 4. Merged / Closed 直接自动归档
        let mergedSnap = GitHubConnector.PRRemoteStatusSnapshot(
            repository: "acme/web",
            number: 4800,
            state: "MERGED",
            merged: true,
            headRefOID: "sha_r1",
            reviews: []
        )
        #expect(GitHubConnector.evaluatePRAutoCompletion(item: makePRItem(), snapshot: mergedSnap, viewerLogin: "boris-w").completionReason == .prMerged)

        let closedSnap = GitHubConnector.PRRemoteStatusSnapshot(
            repository: "acme/web",
            number: 4800,
            state: "CLOSED",
            merged: false,
            headRefOID: "sha_r1",
            reviews: []
        )
        #expect(GitHubConnector.evaluatePRAutoCompletion(item: makePRItem(), snapshot: closedSnap, viewerLogin: "boris-w").completionReason == .prClosed)

        // 5. 先 Approved 后被 Dismissed -> 不归档
        let dismissedSnap = GitHubConnector.PRRemoteStatusSnapshot(
            repository: "acme/web",
            number: 4800,
            state: "OPEN",
            merged: false,
            headRefOID: "sha_r1",
            reviews: [
                .init(state: "APPROVED", authorLogin: "boris-w", submittedAt: now, commitOID: "sha_r1"),
                .init(state: "DISMISSED", authorLogin: "boris-w", submittedAt: newDate, commitOID: "sha_r1")
            ]
        )
        #expect(GitHubConnector.evaluatePRAutoCompletion(item: makePRItem(headSHA: "sha_r1", createdAt: now), snapshot: dismissedSnap, viewerLogin: "boris-w").completionReason == nil)
    }
}
