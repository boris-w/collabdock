import Testing
@testable import CollabDockCore

@Suite("TriggerRuleEngine Multi-Platform Tests [REQ-003][ADR-005]")
struct TriggerRuleEngineTests {
    let engine = TriggerRuleEngine()

    @Test("Accepts GitHub PR @mention with keyword and extracts engine/model/focus hints")
    func githubMentionWithHints() {
        let rules = TriggerRules()
        let event = IncomingCollaborationEvent(
            platform: .github,
            scope: "acme/backend",
            externalRef: "#482",
            triggerKind: .mention,
            actor: "alice",
            body: "@boris 帮忙 review 一下鉴权边界 --model gemini-4-neon-xhigh --focus security"
        )

        let evaluation = engine.evaluate(event: event, currentHandle: "boris", rules: rules)
        #expect(
            evaluation == .accept(
                hints: ParsedTriggerHints(
                    engine: .antigravity,
                    model: "gemini-4-neon-xhigh",
                    focus: "security"
                )
            )
        )
    }

    @Test("Accepts Feishu chat @mention matching channel scope wildcard and keyword")
    func feishuConversationScopeAndKeyword() {
        let rules = TriggerRules(
            requireMentionKeywords: true,
            mentionKeywords: ["排查", "review"],
            scopeAllowlist: ["#支付*", "acme/*"]
        )
        let event = IncomingCollaborationEvent(
            platform: .feishu,
            scope: "#支付值班群",
            externalRef: "话题",
            triggerKind: .mention,
            actor: "diana",
            body: "@boris 帮忙排查一下 504 回调超时"
        )

        #expect(engine.evaluate(event: event, currentHandle: "boris", rules: rules) == .accept(hints: ParsedTriggerHints()))

        let casualChat = IncomingCollaborationEvent(
            platform: .feishu,
            scope: "#支付值班群",
            externalRef: "话题",
            triggerKind: .mention,
            actor: "diana",
            body: "@boris 中午吃什么"
        )
        #expect(engine.evaluate(event: casualChat, currentHandle: "boris", rules: rules) == .reject(.missingMentionKeyword))
    }

    @Test("Supports manual independent toggles for review_requested and assigned")
    func independentToggles() {
        let reviewEvent = IncomingCollaborationEvent(
            platform: .github,
            scope: "acme/web",
            externalRef: "#191",
            triggerKind: .reviewRequested,
            actor: "bob"
        )
        #expect(
            engine.evaluate(event: reviewEvent, currentHandle: "boris", rules: TriggerRules(enableReviewRequested: true))
            == .accept(hints: ParsedTriggerHints())
        )
        #expect(
            engine.evaluate(event: reviewEvent, currentHandle: "boris", rules: TriggerRules(enableReviewRequested: false))
            == .reject(.triggerKindDisabled)
        )

        let linearAssign = IncomingCollaborationEvent(
            platform: .linear,
            scope: "ENG",
            externalRef: "ENG-204",
            triggerKind: .assigned,
            actor: "pm"
        )
        #expect(
            engine.evaluate(event: linearAssign, currentHandle: "boris", rules: TriggerRules(enableAssigned: true))
            == .accept(hints: ParsedTriggerHints())
        )
        #expect(
            engine.evaluate(event: linearAssign, currentHandle: "boris", rules: TriggerRules(enableAssigned: false))
            == .reject(.triggerKindDisabled)
        )
    }

    @Test("Enforces self-trigger guard, bot filter, draft filter, and scope denylist")
    func guardsAndDenylist() {
        let rules = TriggerRules(
            scopeAllowlist: ["acme/*"],
            scopeDenylist: ["acme/sandbox"],
            ignoreDraftItems: true,
            ignoreBots: true
        )

        let selfEvent = IncomingCollaborationEvent(
            platform: .github,
            scope: "acme/core",
            externalRef: "#1",
            triggerKind: .mention,
            actor: "boris",
            body: "@boris review"
        )
        #expect(engine.evaluate(event: selfEvent, currentHandle: "boris", rules: rules) == .reject(.selfTriggered))

        let botEvent = IncomingCollaborationEvent(
            platform: .github,
            scope: "acme/core",
            externalRef: "#2",
            triggerKind: .reviewRequested,
            actor: "dependabot[bot]"
        )
        #expect(engine.evaluate(event: botEvent, currentHandle: "boris", rules: rules) == .reject(.botActor))

        let draftEvent = IncomingCollaborationEvent(
            platform: .github,
            scope: "acme/core",
            externalRef: "#3",
            triggerKind: .reviewRequested,
            actor: "alice",
            isDraftItem: true
        )
        #expect(engine.evaluate(event: draftEvent, currentHandle: "boris", rules: rules) == .reject(.draftItemIgnored))

        let deniedScope = IncomingCollaborationEvent(
            platform: .github,
            scope: "acme/sandbox",
            externalRef: "#4",
            triggerKind: .reviewRequested,
            actor: "alice"
        )
        #expect(engine.evaluate(event: deniedScope, currentHandle: "boris", rules: rules) == .reject(.scopeDenied))

        let outsideAllowlist = IncomingCollaborationEvent(
            platform: .gitlab,
            scope: "other/repo",
            externalRef: "!10",
            triggerKind: .reviewRequested,
            actor: "alice"
        )
        #expect(engine.evaluate(event: outsideAllowlist, currentHandle: "boris", rules: rules) == .reject(.scopeNotAllowed))
    }
}
