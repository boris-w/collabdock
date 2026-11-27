import Foundation

/// 收件箱 GitHub PR 远端状态纯逻辑对齐器（与网络/持久化解耦，按 itemID 回写避免 await 期间下标漂移，关联 ITER-017）
public enum PRStateReconciler {
    public struct Target: Equatable, Hashable, Sendable {
        public let repository: String
        public let number: Int
        public let key: String

        public init(repository: String, number: Int, key: String? = nil) {
            self.repository = repository
            self.number = number
            self.key = key ?? PRStateReconciler.key(repository: repository, number: number)
        }
    }

    public struct Update: Equatable, Hashable, Sendable {
        public let itemID: String
        public let completionReason: TaskCompletionReason?
        public let latestViewerVerdict: String?

        public init(
            itemID: String,
            completionReason: TaskCompletionReason?,
            latestViewerVerdict: String?
        ) {
            self.itemID = itemID
            self.completionReason = completionReason
            self.latestViewerVerdict = latestViewerVerdict
        }
    }

    /// 生成与 `GitHubConnector.fetchPRStatusSnapshots` 完全一致的规范化 PR 键（小写 `owner/repo#number`）
    public static func key(repository: String, number: Int) -> String {
        let normalizedRepo = repository.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedRepo)#\(number)"
    }

    /// 判定某条目是否参与远端 PR 状态自动对齐：跳过演示条目、非 GitHub/非 PR、已归档以及正在本地或 Lody 后台执行中的条目
    public static func isEligible(_ item: CollaborationItem) -> Bool {
        guard item.platform == .github,
              !item.id.hasPrefix("demo-"),
              item.status.isInboxActive,
              item.status != .preparing && item.status != .running && item.status != .publishing,
              item.remoteSessionStatus != .running,
              case .codeChange(let code) = item.payload,
              code.number > 0,
              !code.repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    /// 提取收件箱中需要批量查询远端状态的去重 PR 目标（保持首次出现顺序，大小写不敏感去重）
    public static func targets(in items: [CollaborationItem]) -> [Target] {
        var result: [Target] = []
        var seen: Set<String> = []
        for item in items {
            guard isEligible(item), case .codeChange(let code) = item.payload else {
                continue
            }
            let normalizedKey = Self.key(repository: code.repository, number: code.number)
            if seen.insert(normalizedKey).inserted {
                result.append(
                    Target(
                        repository: code.repository,
                        number: code.number,
                        key: normalizedKey
                    )
                )
            }
        }
        return result
    }

    /// 基于 await 完成后的最新 `items` 快照计算需要回写的条目更新（按 itemID 绑定，未变化时不产出更新避免重复写库）
    public static func updates(
        for items: [CollaborationItem],
        snapshots: [String: GitHubConnector.PRRemoteStatusSnapshot],
        viewerLogin: String
    ) -> [Update] {
        var result: [Update] = []
        for item in items {
            guard isEligible(item), case .codeChange(let code) = item.payload else {
                continue
            }
            let lookupKey = Self.key(repository: code.repository, number: code.number)
            guard let snapshot = snapshots[lookupKey] else {
                continue
            }
            let eval = GitHubConnector.evaluatePRAutoCompletion(
                item: item,
                snapshot: snapshot,
                viewerLogin: viewerLogin
            )
            if let reason = eval.completionReason {
                result.append(
                    Update(
                        itemID: item.id,
                        completionReason: reason,
                        latestViewerVerdict: eval.latestViewerVerdict
                    )
                )
            } else if eval.latestViewerVerdict != item.gitHubReviewVerdict {
                result.append(
                    Update(
                        itemID: item.id,
                        completionReason: nil,
                        latestViewerVerdict: eval.latestViewerVerdict
                    )
                )
            }
        }
        return result
    }

    /// 将单条对齐更新应用到目标条目
    public static func apply(_ update: Update, to item: inout CollaborationItem) {
        if let reason = update.completionReason {
            item.status = .completed
            item.completionReason = reason
            item.gitHubReviewVerdict = update.latestViewerVerdict
            item.progressMessage = nil
            item.errorMessage = nil
        } else {
            item.gitHubReviewVerdict = update.latestViewerVerdict
        }
    }
}
