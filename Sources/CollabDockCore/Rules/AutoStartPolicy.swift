import Foundation

/// 判断一条新同步的协作请求是否满足「自动开始审查」策略（纯函数，关联 PR #21）
public enum AutoStartPolicy {
    public static func shouldAutoStart(
        _ item: CollaborationItem,
        settings: AutoStartSettings
    ) -> Bool {
        guard settings.isEnabled, !settings.isPaused else {
            return false
        }
        guard item.platform == .github,
              item.itemKind == .pullRequest,
              item.status == .pendingConfirmation,
              !item.id.hasPrefix("demo-") else {
            return false
        }
        guard case .codeChange(let code) = item.payload else {
            return false
        }
        guard settings.triggerKinds.contains(item.triggerKind) else {
            return false
        }
        if item.previousReview != nil && !settings.continueReReviews {
            return false
        }

        let activePatterns = settings.repositoryAllowlist
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !activePatterns.isEmpty && !matchesAnyPattern(code.repository, patterns: activePatterns) {
            return false
        }
        return true
    }

    private static func matchesAnyPattern(_ repository: String, patterns: [String]) -> Bool {
        let target = repository.lowercased()
        for raw in patterns {
            let pattern = raw.lowercased()
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
}
