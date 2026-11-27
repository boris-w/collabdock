import Foundation
import Testing
@testable import CollabDockCore

/// SPEC（实现前为红）：在「我是 reviewer」的 PR 上，任何 @我 都触发（不要求关键词）。
/// 「我是 reviewer」= 我仍在 requested_reviewers 中，**或**我已在该 PR 上提交过 review
/// （提交 review 后 GitHub 会把我移出 requested_reviewers，作者此时 @ 我追问正是需要触发的场景）；
/// 其他 PR 仍按关键词规则过滤，避免闲聊打扰。自 @、机器人、仓库黑名单等保护照常生效。
@Suite("SPEC — bare @mentions on PRs I review")
struct MentionOnReviewerPRSpecTests {
    private let engine = TriggerRuleEngine()

    private func mention(body: String, actor: String = "carol", scope: String = "acme/backend", requested: Bool) -> IncomingCollaborationEvent {
        IncomingCollaborationEvent(
            platform: .github,
            scope: scope,
            externalRef: "#7",
            triggerKind: .mention,
            actor: actor,
            body: body,
            viewerIsReviewer: requested
        )
    }

    @Test("A bare @me on a PR I review (requested or already reviewed) triggers even without keywords")
    func bareMentionOnRequestedPRTriggers() {
        guard case .accept = engine.evaluate(event: mention(body: "@me ", requested: true), currentHandle: "me", rules: TriggerRules()) else {
            Issue.record("expected accept"); return
        }
    }

    @Test("Elsewhere the keyword rule still applies (default behavior unchanged)")
    func keywordRuleStillAppliesElsewhere() {
        #expect(engine.evaluate(event: mention(body: "@me lunch?", requested: false), currentHandle: "me", rules: TriggerRules())
                == .reject(.missingMentionKeyword))
        guard case .accept = engine.evaluate(event: mention(body: "@me please review", requested: false), currentHandle: "me", rules: TriggerRules()) else {
            Issue.record("keyword mentions must keep working"); return
        }
    }

    @Test("Other protections still win on PRs I review: self-mention, bots, denied scopes, disabled mentions")
    func otherProtectionsStillApply() {
        #expect(engine.evaluate(event: mention(body: "@me ", actor: "me", requested: true), currentHandle: "me", rules: TriggerRules())
                == .reject(.selfTriggered))
        #expect(engine.evaluate(event: mention(body: "@me ", actor: "ci-bot[bot]", requested: true), currentHandle: "me", rules: TriggerRules())
                == .reject(.botActor))

        var denied = TriggerRules()
        denied.scopeDenylist = ["acme/*"]
        #expect(engine.evaluate(event: mention(body: "@me ", requested: true), currentHandle: "me", rules: denied) == .reject(.scopeDenied))

        var mentionsOff = TriggerRules()
        mentionsOff.enableMention = false
        #expect(engine.evaluate(event: mention(body: "@me ", requested: true), currentHandle: "me", rules: mentionsOff) == .reject(.triggerKindDisabled))
    }

    @Test("Existing callers keep compiling: the new flag defaults to false")
    func flagDefaultsToFalse() {
        let event = IncomingCollaborationEvent(platform: .github, scope: "acme/backend", externalRef: "#7", triggerKind: .mention, actor: "carol", body: "@me ")
        #expect(event.viewerIsReviewer == false)
    }
}
