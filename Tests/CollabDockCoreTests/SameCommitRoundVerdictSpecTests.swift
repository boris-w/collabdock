import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（修复前为红）：同一提交上的第 2 轮复审卡片，不能继承第 1 轮在同一个 SHA 上留下的 review 结论。
/// 否则旧的 CHANGES_REQUESTED 会让新卡片一入箱就显示「待修复」，旧的 APPROVED 甚至会把新卡片立即自动归档（复审请求再次被吞）。
@Suite("SPEC — PR auto-completion for a same-commit re-review round")
struct SameCommitRoundVerdictSpecTests {
    static let sha = "abcdef0123456789abcdef0123456789abcdef01"
    static let roundOneReview = Date(timeIntervalSince1970: 1_800_000_000)          // 我第 1 轮提交 review 的时间
    static let roundTwoCreated = roundOneReview.addingTimeInterval(2 * 3600)          // 再次请求后第 2 轮卡片入箱

    private func item(round: Int, previousSHA: String?, createdAt: Date = roundTwoCreated) -> CollaborationItem {
        CollaborationItem(
            id: "github:acme/web#4800:reviewRequested:\(Self.sha)@2026-11-27T05:37:16Z",
            platform: .github,
            itemKind: .pullRequest,
            scope: "acme/web",
            externalRef: "#4800",
            title: "fix: cursor paging",
            url: URL(string: "https://github.com/acme/web/pull/4800")!,
            author: "carol",
            triggeredBy: "carol",
            triggerKind: .reviewRequested,
            payload: .codeChange(CodeChangePayload(
                repository: "acme/web", number: 4800, baseRef: "develop", headRef: "fix/paging",
                headSHA: Self.sha, additions: 10, deletions: 2, changedFiles: 1
            )),
            createdAt: createdAt,
            status: .pendingConfirmation,
            previousReview: previousSHA.map {
                PreviousReviewContext(previousItemID: "r1", reviewedHeadSHA: $0, reviewedAt: Self.roundOneReview, engine: .lody, sessionID: "s1", reviewRound: round - 1)
            },
            reviewRound: round
        )
    }

    private func snapshot(_ reviews: [GitHubConnector.PRRemoteReviewEntry]) -> GitHubConnector.PRRemoteStatusSnapshot {
        GitHubConnector.PRRemoteStatusSnapshot(repository: "acme/web", number: 4800, state: "OPEN", merged: false, headRefOID: Self.sha, reviews: reviews)
    }

    private func review(_ state: String, at date: Date) -> GitHubConnector.PRRemoteReviewEntry {
        .init(state: state, authorLogin: "me", submittedAt: date, commitOID: Self.sha)
    }

    @Test("SPEC: round 1's CHANGES_REQUESTED on the same commit does not mark the new round as 'needs fix'")
    func oldChangesRequestedDoesNotCarryOver() {
        let eval = GitHubConnector.evaluatePRAutoCompletion(
            item: item(round: 2, previousSHA: Self.sha),
            snapshot: snapshot([review("CHANGES_REQUESTED", at: Self.roundOneReview)]),
            viewerLogin: "me"
        )
        #expect(eval.completionReason == nil)
        #expect(eval.latestViewerVerdict == nil)
    }

    @Test("SPEC: round 1's APPROVED on the same commit does not auto-archive the new round")
    func oldApprovalDoesNotArchiveNewRound() {
        let eval = GitHubConnector.evaluatePRAutoCompletion(
            item: item(round: 2, previousSHA: Self.sha),
            snapshot: snapshot([review("APPROVED", at: Self.roundOneReview)]),
            viewerLogin: "me"
        )
        #expect(eval.completionReason == nil)
    }

    @Test("An approval submitted during the new round still archives it")
    func newApprovalArchivesNewRound() {
        let eval = GitHubConnector.evaluatePRAutoCompletion(
            item: item(round: 2, previousSHA: Self.sha),
            snapshot: snapshot([
                review("CHANGES_REQUESTED", at: Self.roundOneReview),
                review("APPROVED", at: Self.roundTwoCreated.addingTimeInterval(600))
            ]),
            viewerLogin: "me"
        )
        #expect(eval.completionReason == .prApproved)
    }

    @Test("Safety net: a first-round card still honours a review I submitted on GitHub before CollabDock picked the request up")
    func firstRoundStillMatchesByCommit() {
        let eval = GitHubConnector.evaluatePRAutoCompletion(
            item: item(round: 1, previousSHA: nil, createdAt: Self.roundOneReview.addingTimeInterval(900)),
            snapshot: snapshot([review("APPROVED", at: Self.roundOneReview)]),
            viewerLogin: "me"
        )
        #expect(eval.completionReason == .prApproved)
    }
}
