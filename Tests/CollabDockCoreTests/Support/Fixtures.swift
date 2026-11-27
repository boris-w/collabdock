import Foundation
@testable import CollabDockCore

/// 单元测试共用的 GitHub PR 条目构造器
enum Fixtures {
    static func prItem(
        repository: String = "acme/backend",
        number: Int = 1,
        headSHA: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        status: CollaborationTaskStatus = .draftReady,
        remoteSessionStatus: RemoteSessionStatus? = nil,
        verdict: String? = nil,
        idPrefix: String = "github",
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> CollaborationItem {
        CollaborationItem(
            id: "\(idPrefix):\(repository)#\(number):reviewRequested:\(headSHA.prefix(7))",
            platform: .github,
            itemKind: .pullRequest,
            scope: repository,
            externalRef: "#\(number)",
            title: "PR \(number)",
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
            author: "alice",
            triggeredBy: "alice",
            triggerKind: .reviewRequested,
            payload: .codeChange(
                CodeChangePayload(
                    repository: repository,
                    number: number,
                    baseRef: "main",
                    headRef: "feat/\(number)",
                    headSHA: headSHA,
                    additions: 10,
                    deletions: 2,
                    changedFiles: 1
                )
            ),
            createdAt: createdAt,
            status: status,
            remoteSessionStatus: remoteSessionStatus,
            gitHubReviewVerdict: verdict
        )
    }

    static func chatItem(id: String = "feishu:thread-1") -> CollaborationItem {
        CollaborationItem(
            id: id,
            platform: .feishu,
            itemKind: .conversation,
            scope: "#oncall",
            externalRef: "Thread",
            title: "线上报错排查",
            url: URL(string: "https://example.com/thread/1")!,
            author: "bob",
            triggeredBy: "bob",
            triggerKind: .mention,
            payload: .conversation(
                ConversationPayload(channelName: "#oncall", threadID: "t1")
            )
        )
    }

    static func snapshot(
        repository: String,
        number: Int,
        state: String = "OPEN",
        merged: Bool = false,
        headRefOID: String? = nil,
        reviews: [GitHubConnector.PRRemoteReviewEntry] = []
    ) -> (key: String, value: GitHubConnector.PRRemoteStatusSnapshot) {
        (
            PRStateReconciler.key(repository: repository, number: number),
            GitHubConnector.PRRemoteStatusSnapshot(
                repository: repository,
                number: number,
                state: state,
                merged: merged,
                headRefOID: headRefOID,
                reviews: reviews
            )
        )
    }
}
