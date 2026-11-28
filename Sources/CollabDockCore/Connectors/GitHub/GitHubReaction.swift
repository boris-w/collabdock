import Foundation

/// GitHub 表情反应内容（ADR-009：CollabDock 仅使用 `eyes` 👀 标记开始审查）
public enum GitHubReactionContent: String, Codable, Hashable, Sendable {
    case eyes
}

/// 开始审查时在 PR 或触发评论上添加表情反应的协议（ADR-009：CollabDock 唯一的 GitHub 写操作）
public protocol PullRequestReacting: Sendable {
    func addReaction(_ content: GitHubReactionContent, to item: CollaborationItem) async throws
}

/// 严格校验并生成 GitHub Reaction 写入端点：绝不把 token 发往非配置 API 主机或异常路径（ADR-009）
public enum GitHubReactionTarget {
    public static func endpoint(
        for item: CollaborationItem,
        apiBaseURL: URL
    ) -> URL? {
        guard item.platform == .github,
              case .codeChange(let code) = item.payload else {
            return nil
        }

        if let commentURL = item.triggerCommentAPIURL,
           isTrustedCommentURL(commentURL, repository: code.repository, apiBaseURL: apiBaseURL) {
            return commentURL.appendingPathComponent("reactions")
        }

        return apiBaseURL.appendingPathComponent("repos/\(code.repository)/issues/\(code.number)/reactions")
    }

    private static func isTrustedCommentURL(
        _ commentURL: URL,
        repository: String,
        apiBaseURL: URL
    ) -> Bool {
        guard let commentComp = URLComponents(url: commentURL, resolvingAgainstBaseURL: false),
              let baseComp = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            return false
        }

        // 1. 协议、主机（大小写不敏感）与端口必须完全一致
        guard let cScheme = commentComp.scheme?.lowercased(),
              let bScheme = baseComp.scheme?.lowercased(),
              cScheme == bScheme,
              let cHost = commentComp.host?.lowercased(),
              let bHost = baseComp.host?.lowercased(),
              !cHost.isEmpty,
              cHost == bHost,
              commentComp.port == baseComp.port else {
            return false
        }

        // 2. 禁止 userinfo、query、fragment
        guard commentComp.user == nil,
              commentComp.password == nil,
              commentComp.query == nil,
              commentComp.fragment == nil else {
            return false
        }

        // 3. 原始未归一化路径严格匹配 `<api path>/repos/<same repo>/(issues|pulls)/comments/<digits>`
        let rawPath = commentComp.percentEncodedPath
        guard rawPath.hasPrefix("/"), !rawPath.contains("%") else {
            return false
        }
        let pathParts = rawPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard pathParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        let segments = pathParts.map(String.init)

        let baseSegments = baseComp.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        let repoParts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard repoParts.count == 2,
              !repoParts[0].isEmpty,
              !repoParts[1].isEmpty else {
            return false
        }

        guard segments.count == baseSegments.count + 6 else {
            return false
        }
        if !baseSegments.isEmpty && Array(segments.prefix(baseSegments.count)) != baseSegments {
            return false
        }

        let tail = Array(segments.dropFirst(baseSegments.count))
        guard tail[0] == "repos",
              tail[1].lowercased() == repoParts[0].lowercased(),
              tail[2].lowercased() == repoParts[1].lowercased(),
              (tail[3] == "issues" || tail[3] == "pulls"),
              tail[4] == "comments",
              !tail[5].isEmpty,
              tail[5].unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }) else {
            return false
        }

        return true
    }
}
