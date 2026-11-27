import Foundation

public struct IncomingCollaborationEvent: Hashable, Sendable {
    public let platform: PlatformKind
    public let scope: String
    public let externalRef: String
    public let triggerKind: TriggerKind
    public let actor: String
    public let isDraftItem: Bool
    public let body: String?

    public init(
        platform: PlatformKind,
        scope: String,
        externalRef: String,
        triggerKind: TriggerKind,
        actor: String,
        isDraftItem: Bool = false,
        body: String? = nil
    ) {
        self.platform = platform
        self.scope = scope
        self.externalRef = externalRef
        self.triggerKind = triggerKind
        self.actor = actor
        self.isDraftItem = isDraftItem
        self.body = body
    }
}

public struct ParsedTriggerHints: Hashable, Sendable {
    public let engine: AgentEngine?
    public let model: String?
    public let focus: String?

    public init(engine: AgentEngine? = nil, model: String? = nil, focus: String? = nil) {
        self.engine = engine
        self.model = model
        self.focus = focus
    }
}

public enum TriggerRejectionReason: String, Equatable, Sendable {
    case selfTriggered
    case botActor
    case draftItemIgnored
    case scopeDenied
    case scopeNotAllowed
    case triggerKindDisabled
    case missingDirectMention
    case missingMentionKeyword
}

public enum TriggerEvaluation: Equatable, Sendable {
    case accept(hints: ParsedTriggerHints)
    case reject(TriggerRejectionReason)
}

/// 跨平台统一触发规则引擎（支持 GitHub / GitLab / 飞书 / Slack / Linear，关联 REQ-003, ADR-005）
public struct TriggerRuleEngine: Sendable {
    public init() {}

    public func evaluate(
        event: IncomingCollaborationEvent,
        currentHandle: String,
        rules: TriggerRules
    ) -> TriggerEvaluation {
        let normalizedMe = currentHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedActor = event.actor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !normalizedMe.isEmpty && normalizedActor == normalizedMe {
            return .reject(.selfTriggered)
        }

        if rules.ignoreBots && isBotLogin(normalizedActor) {
            return .reject(.botActor)
        }

        if rules.ignoreDraftItems && event.isDraftItem {
            return .reject(.draftItemIgnored)
        }

        if matchesAnyPattern(event.scope, patterns: rules.scopeDenylist) {
            return .reject(.scopeDenied)
        }

        if !rules.scopeAllowlist.isEmpty && !matchesAnyPattern(event.scope, patterns: rules.scopeAllowlist) {
            return .reject(.scopeNotAllowed)
        }

        switch event.triggerKind {
        case .reviewRequested:
            guard rules.enableReviewRequested else {
                return .reject(.triggerKindDisabled)
            }
            return .accept(hints: ParsedTriggerHints())

        case .assigned:
            guard rules.enableAssigned else {
                return .reject(.triggerKindDisabled)
            }
            let hints = rules.parseTriggerHints ? parseHints(from: event.body ?? "") : ParsedTriggerHints()
            return .accept(hints: hints)

        case .teamMention:
            guard rules.enableTeamMention else {
                return .reject(.triggerKindDisabled)
            }
            let hints = rules.parseTriggerHints ? parseHints(from: event.body ?? "") : ParsedTriggerHints()
            return .accept(hints: hints)

        case .mention, .threadReply:
            guard rules.enableMention else {
                return .reject(.triggerKindDisabled)
            }
            let body = event.body ?? ""
            if event.triggerKind == .mention && !normalizedMe.isEmpty && !containsDirectMention(of: normalizedMe, in: body) {
                return .reject(.missingDirectMention)
            }
            if rules.requireMentionKeywords && !containsAnyKeyword(rules.mentionKeywords, in: body) {
                return .reject(.missingMentionKeyword)
            }
            let hints = rules.parseTriggerHints ? parseHints(from: body) : ParsedTriggerHints()
            return .accept(hints: hints)
        }
    }

    public func parseHints(from body: String) -> ParsedTriggerHints {
        var engine: AgentEngine?
        var model: String?
        var focus: String?

        if let extractedModel = firstCapture(
            pattern: #"(?:--model\s+|model:)([A-Za-z0-9._\-/]+)"#,
            in: body
        ) {
            model = extractedModel
            engine = inferEngine(fromModel: extractedModel)
        }

        if let extractedEngine = firstCapture(
            pattern: #"(?:--engine|--cli)\s+([A-Za-z0-9\-]+)"#,
            in: body
        )?.lowercased() {
            switch extractedEngine {
            case "claude", "claude-code":
                engine = .claudeCode
            case "codex":
                engine = .codex
            case "agy", "antigravity":
                engine = .antigravity
            case "lody", "lody.ai":
                engine = .lody
            default:
                break
            }
        }

        if let extractedFocus = firstCapture(
            pattern: #"(?:--focus\s+|focus:)([A-Za-z0-9._\-]+)"#,
            in: body
        ) {
            focus = extractedFocus
        }

        return ParsedTriggerHints(engine: engine, model: model, focus: focus)
    }

    private func isBotLogin(_ login: String) -> Bool {
        login.hasSuffix("[bot]") || login.hasSuffix("-bot")
    }

    private func containsDirectMention(of handle: String, in body: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: handle)
        let pattern = #"(?:^|[^A-Za-z0-9_-])@"# + escaped + #"(?:$|[^A-Za-z0-9_-])"#
        return firstMatch(pattern: pattern, in: body, caseInsensitive: true) != nil
    }

    private func containsAnyKeyword(_ keywords: [String], in body: String) -> Bool {
        let lowerBody = body.lowercased()
        let activeKeywords = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !activeKeywords.isEmpty else { return true }
        return activeKeywords.contains { keyword in
            if keyword.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
                let escaped = NSRegularExpression.escapedPattern(for: keyword)
                return firstMatch(pattern: #"\b"# + escaped + #"\b"#, in: lowerBody, caseInsensitive: true) != nil
            }
            return lowerBody.contains(keyword)
        }
    }

    private func matchesAnyPattern(_ scope: String, patterns: [String]) -> Bool {
        let target = scope.lowercased()
        for raw in patterns {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty else { continue }
            if pattern == "*" || pattern == target {
                return true
            }
            if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast(1))
                if target.hasPrefix(prefix) {
                    return true
                }
            }
        }
        return false
    }

    private func inferEngine(fromModel model: String) -> AgentEngine? {
        let lower = model.lowercased()
        if lower.contains("gemini") || lower.contains("neon") || lower.contains("carbon") || lower.contains("argon") {
            return .antigravity
        }
        if lower.contains("codex") || lower.hasPrefix("gpt-") || lower == "o3" || lower == "o4-mini" {
            return .codex
        }
        if lower.contains("opus") || lower.contains("sonnet") || lower.contains("haiku") || lower.contains("claude") {
            return .claudeCode
        }
        return nil
    }

    private func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private func firstMatch(pattern: String, in text: String, caseInsensitive: Bool) -> NSTextCheckingResult? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range)
    }
}
