import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：可选的「收到请求后自动开始审查」——设置与判定规则。
///
/// - 默认关闭；打开后默认只对「请你 Review」生效，可以加上 @我 / 指派 / 团队提及；
/// - 仓库名单为空表示「所有已通过现有触发规则的仓库」，非空时按 `owner/*` 通配匹配；
/// - PR 更新后的复审默认也自动开始（接着同一个 Lody 对话），可单独关掉；
/// - 暂停时一律不自动开始。
@Suite("SPEC — auto-start review: settings and policy")
struct AutoStartSpecTests {
    private func pr(
        repository: String = "acme/backend",
        trigger: TriggerKind = .reviewRequested,
        status: CollaborationTaskStatus = .pendingConfirmation,
        previous: Bool = false,
        id: String? = nil
    ) -> CollaborationItem {
        var item = CollaborationItem(
            id: id ?? "github:\(repository)#7:\(trigger.rawValue):abc1234",
            platform: .github,
            itemKind: .pullRequest,
            scope: repository,
            externalRef: "#7",
            title: "PR 7",
            url: URL(string: "https://github.com/\(repository)/pull/7")!,
            author: "alice",
            triggeredBy: "alice",
            triggerKind: trigger,
            payload: .codeChange(CodeChangePayload(
                repository: repository, number: 7, baseRef: "main", headRef: "feat/7",
                headSHA: "abc1234abc1234abc1234abc1234abc1234abc12", additions: 1, deletions: 0, changedFiles: 1
            )),
            status: status
        )
        if previous {
            item.previousReview = PreviousReviewContext(
                previousItemID: "github:\(repository)#7:reviewRequested:0000000",
                reviewedHeadSHA: "0000000000000000000000000000000000000000",
                reviewedAt: Date(timeIntervalSince1970: 1_800_000_000),
                engine: .lody,
                sessionID: "lody-1",
                reviewRound: 1
            )
            item.reviewRound = 2
        }
        return item
    }

    private var enabled: AutoStartSettings {
        var s = AutoStartSettings()
        s.isEnabled = true
        return s
    }

    // MARK: settings

    @Test("Defaults: off, review requests only, all repos, re-reviews continue, notify on start, not paused; 👀 on")
    func defaults() {
        let s = AppSettings()
        #expect(s.autoStart.isEnabled == false)
        #expect(s.autoStart.triggerKinds == [.reviewRequested])
        #expect(s.autoStart.repositoryAllowlist.isEmpty)
        #expect(s.autoStart.continueReReviews == true)
        #expect(s.autoStart.notifyOnStart == true)
        #expect(s.autoStart.isPaused == false)
        #expect(s.markReviewStartWithReaction == true)
        #expect(AutoStartSettings() == s.autoStart)
    }

    @Test("Settings saved before this feature load with the defaults")
    func legacyDecode() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"pollIntervalSeconds": 120}"#.utf8))
        #expect(decoded.autoStart == AutoStartSettings())
        #expect(decoded.markReviewStartWithReaction == true)
        #expect(decoded.pollIntervalSeconds == 120)
    }

    @Test("Every field survives a save / load round trip")
    func roundTrip() throws {
        var s = AppSettings()
        s.autoStart = AutoStartSettings(
            isEnabled: true,
            triggerKinds: [.reviewRequested, .mention],
            repositoryAllowlist: ["acme/web-*"],
            continueReReviews: false,
            notifyOnStart: false,
            isPaused: true
        )
        s.markReviewStartWithReaction = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded.autoStart == s.autoStart)
        #expect(decoded.markReviewStartWithReaction == false)
    }

    @Test("A bad field (e.g. an unknown trigger kind from a newer version) falls back alone, without failing the file")
    func badFieldFallsBackAlone() throws {
        let json = #"{"pollIntervalSeconds": 300, "autoStart": {"isEnabled": true, "triggerKinds": ["reviewRequested", "fromTheFuture"], "isPaused": true}}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.pollIntervalSeconds == 300)
        #expect(decoded.autoStart.isEnabled == true)
        #expect(decoded.autoStart.isPaused == true)
        #expect(decoded.autoStart.triggerKinds == [.reviewRequested], "the unreadable list falls back to the default")
        #expect(decoded.autoStart.continueReReviews == true)
    }

    // MARK: policy

    @Test("Off or paused: never auto-starts")
    func offOrPaused() {
        #expect(AutoStartPolicy.shouldAutoStart(pr(), settings: AutoStartSettings()) == false)
        var paused = enabled
        paused.isPaused = true
        #expect(AutoStartPolicy.shouldAutoStart(pr(), settings: paused) == false)
    }

    @Test("Enabled: a new review request on any repo auto-starts")
    func reviewRequestStarts() {
        #expect(AutoStartPolicy.shouldAutoStart(pr(), settings: enabled))
        #expect(AutoStartPolicy.shouldAutoStart(pr(repository: "acme/web-console"), settings: enabled))
    }

    @Test("Only the selected trigger kinds auto-start", arguments: [TriggerKind.mention, .assigned, .teamMention, .threadReply])
    func unselectedTriggerKindsWait(kind: TriggerKind) {
        #expect(AutoStartPolicy.shouldAutoStart(pr(trigger: kind), settings: enabled) == false)
        var all = enabled
        all.triggerKinds = [.reviewRequested, kind]
        #expect(AutoStartPolicy.shouldAutoStart(pr(trigger: kind), settings: all))
    }

    @Test("A repository list limits auto-start, with owner/* style patterns")
    func repositoryAllowlist() {
        var s = enabled
        s.repositoryAllowlist = ["acme/web-*", "acme/billing"]
        #expect(AutoStartPolicy.shouldAutoStart(pr(repository: "acme/web-console"), settings: s))
        #expect(AutoStartPolicy.shouldAutoStart(pr(repository: "acme/billing"), settings: s))
        #expect(AutoStartPolicy.shouldAutoStart(pr(repository: "acme/backend"), settings: s) == false)

        s.repositoryAllowlist = ["acme/*"]
        #expect(AutoStartPolicy.shouldAutoStart(pr(repository: "acme/backend"), settings: s))
        #expect(AutoStartPolicy.shouldAutoStart(pr(repository: "other/backend"), settings: s) == false)
    }

    @Test("Re-reviews auto-start by default and wait for you when that is turned off")
    func reReviews() {
        #expect(AutoStartPolicy.shouldAutoStart(pr(previous: true), settings: enabled))
        var s = enabled
        s.continueReReviews = false
        #expect(AutoStartPolicy.shouldAutoStart(pr(previous: true), settings: s) == false)
        #expect(AutoStartPolicy.shouldAutoStart(pr(previous: false), settings: s), "first reviews are unaffected")
    }

    @Test("Only new, pending GitHub pull requests qualify; demo and already-handled items never do",
          arguments: [CollaborationTaskStatus.preparing, .running, .draftReady, .failed, .completed])
    func onlyPendingItems(status: CollaborationTaskStatus) {
        #expect(AutoStartPolicy.shouldAutoStart(pr(status: status), settings: enabled) == false)
    }

    @Test("Demo items and non-GitHub items never auto-start")
    func demoAndOtherPlatforms() {
        #expect(AutoStartPolicy.shouldAutoStart(pr(id: "demo-pr-1"), settings: enabled) == false)

        let chat = CollaborationItem(
            id: "feishu:thread-1",
            platform: .feishu,
            itemKind: .conversation,
            scope: "#oncall",
            externalRef: "Thread",
            title: "help",
            url: URL(string: "https://example.com/thread/1")!,
            author: "bob",
            triggeredBy: "bob",
            triggerKind: .reviewRequested,
            payload: .conversation(ConversationPayload(channelName: "#oncall", threadID: "t1"))
        )
        #expect(AutoStartPolicy.shouldAutoStart(chat, settings: enabled) == false)
    }
}
