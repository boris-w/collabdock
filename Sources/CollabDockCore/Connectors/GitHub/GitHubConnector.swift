import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPTransport: HTTPTransport {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubConnectorError.invalidResponse
        }
        return (data, http)
    }
}

public protocol GitHubTokenProvider: Sendable {
    func fetchToken() async -> String?
}

public struct DefaultGitHubTokenProvider: GitHubTokenProvider {
    private let detector: any EnvironmentDetecting
    private let ghExecutablePath: String?
    private let manualPAT: String?

    public init(
        detector: any EnvironmentDetecting = EnvironmentDetector(),
        ghExecutablePath: String? = nil,
        manualPAT: String? = nil
    ) {
        self.detector = detector
        self.ghExecutablePath = ghExecutablePath
        self.manualPAT = manualPAT
    }

    public func fetchToken() async -> String? {
        await detector.resolveGitHubToken(ghExecutablePath: ghExecutablePath, manualPAT: manualPAT)
    }
}

public enum GitHubConnectorError: Error, LocalizedError, Equatable {
    case missingToken
    case invalidResponse
    case unauthorized
    case rateLimited(retryAfterSeconds: Int)
    case httpError(statusCode: Int, message: String)
    case pendingReviewAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "未检测到 GitHub 凭据，请运行 `gh auth login` 或在设置中填入 PAT"
        case .invalidResponse:
            return "GitHub 返回了无效的 HTTP 响应"
        case .unauthorized:
            return "GitHub Token 认证失败或已过期，请重新执行 `gh auth login`"
        case .rateLimited(let retryAfter):
            return "触发 GitHub API 速率限制，已自动退避 \(retryAfter) 秒后重试"
        case .httpError(let code, let msg):
            return "GitHub API 错误 (HTTP \(code)): \(msg)"
        case .pendingReviewAlreadyExists:
            return "该 PR 上你已有一个未提交的 Pending Review 草稿，请先在 GitHub 提交或删除旧草稿（本地 Markdown 报告已保存）"
        }
    }
}

/// GitHub 协作连接器：支持 Notifications 304 零配额快速通道 + updated_at 指纹跳过 + 限流退避（关联 REQ-001, REQ-002, ADR-002, ADR-005）
public struct GitHubConnector: CodeReviewConnector {
    public let platform: PlatformKind = .github
    public let capabilities: ConnectorCapabilities = ConnectorCatalog.capabilities(for: .github)

    private let transport: any HTTPTransport
    private let tokenProvider: any GitHubTokenProvider
    private let baseURL: URL
    private let includeReviewRequestedSearch: Bool
    private let includeMentionsSearchFallback: Bool
    private let knownNotificationsScope: Bool?
    private let reconcileReviewRequestedNow: Bool
    private let knownPRUpdatedAt: [String: String]

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        tokenProvider: any GitHubTokenProvider = DefaultGitHubTokenProvider(),
        baseURL: URL = URL(string: "https://api.github.com")!,
        includeReviewRequestedSearch: Bool = true,
        includeMentionsSearchFallback: Bool = true,
        knownNotificationsScope: Bool? = nil,
        reconcileReviewRequestedNow: Bool = true,
        knownPRUpdatedAt: [String: String] = [:]
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.baseURL = baseURL
        self.includeReviewRequestedSearch = includeReviewRequestedSearch
        self.includeMentionsSearchFallback = includeMentionsSearchFallback
        self.knownNotificationsScope = knownNotificationsScope
        self.reconcileReviewRequestedNow = reconcileReviewRequestedNow
        self.knownPRUpdatedAt = knownPRUpdatedAt
    }

    public func poll(cursor: SyncCursor?) async throws -> PollBatch {
        try await poll(
            PollRequest(
                cursor: cursor,
                reconcileNow: reconcileReviewRequestedNow,
                knownFingerprints: knownPRUpdatedAt
            )
        )
    }

    public func poll(_ request: PollRequest) async throws -> PollBatch {
        guard let token = await tokenProvider.fetchToken(), !token.isEmpty else {
            throw GitHubConnectorError.missingToken
        }

        var candidatesByKey: [String: PolledCollaborationCandidate] = [:]
        var nextCursor = request.cursor
        var pollInterval: Int?
        var diagnostic: String?
        var wasNotModified = false
        var notificationsForbidden = false
        var latestRateLimit: RateLimitSnapshot?
        var updatedFingerprints = request.knownFingerprints

        // 1. 优先尝试 Notifications API 条件轮询（304 不计入 Primary Rate Limit）
        //    若已通过 gh auth status 明确得知缺少 notifications scope，跳过必然 403 的撞墙请求
        if knownNotificationsScope == false {
            notificationsForbidden = true
            pollInterval = 180
            diagnostic = "当前 gh Token 缺少 notifications 权限（运行 `gh auth refresh -s notifications` 可解锁 304 零配额监听）；已自动按 180s 间隔走 Search API 降级"
        } else {
            let notifURL = baseURL.appendingPathComponent("notifications")
            var notifReq = makeRequest(url: notifURL, token: token)
            if let since = request.cursor?.value, !since.isEmpty {
                notifReq.setValue(since, forHTTPHeaderField: "If-Modified-Since")
            }

            let (notifData, notifResp) = try await transport.data(for: notifReq)
            if let rl = Self.parseRateLimit(from: notifResp) {
                latestRateLimit = rl
            }
            if let rawInterval = notifResp.value(forHTTPHeaderField: "X-Poll-Interval"),
               let parsed = Int(rawInterval) {
                pollInterval = max(60, parsed)
            }
            if let lastModified = notifResp.value(forHTTPHeaderField: "Last-Modified"), !lastModified.isEmpty {
                nextCursor = SyncCursor(value: lastModified)
            }

            if let retryAfter = Self.detectRateLimitBackoff(response: notifResp, rateLimit: latestRateLimit) {
                throw GitHubConnectorError.rateLimited(retryAfterSeconds: retryAfter)
            }

            switch notifResp.statusCode {
            case 304:
                wasNotModified = true
            case 200:
                let threads = (try? JSONDecoder().decode([GHNotificationThread].self, from: notifData)) ?? []
                for thread in threads where thread.subject.type == "PullRequest" {
                    guard let triggerKind = mapNotificationReason(thread.reason) else { continue }
                    if let candidate = await hydrateFromNotificationThread(
                        thread,
                        triggerKind: triggerKind,
                        viewerLogin: request.viewerLogin,
                        token: token
                    ) {
                        candidatesByKey[candidate.dedupeKey] = candidate
                    }
                }
            case 401:
                throw GitHubConnectorError.unauthorized
            case 403:
                notificationsForbidden = true
                pollInterval = max(pollInterval ?? 180, 180)
                diagnostic = "当前 gh Token 缺少 notifications 权限（运行 `gh auth refresh -s notifications` 可解锁 304 零配额监听）；已自动按 180s 间隔走 Search API 降级"
            default:
                throw GitHubConnectorError.httpError(
                    statusCode: notifResp.statusCode,
                    message: String(data: notifData, encoding: .utf8) ?? ""
                )
            }
        }

        // 2. 304 零配额快速通道：无新通知且未到低频对齐周期时，跳过 Search 请求，实现真正 0 消耗
        let shouldRunReviewSearch = includeReviewRequestedSearch && (notificationsForbidden || request.reconcileNow)
        if shouldRunReviewSearch {
            let (reviewCandidates, searchRL) = try await searchOpenPRs(
                query: "is:pr is:open review-requested:@me",
                triggerKind: .reviewRequested,
                fetchLatestComment: false,
                viewerLogin: request.viewerLogin,
                token: token,
                fingerprints: &updatedFingerprints
            )
            if let searchRL, latestRateLimit == nil {
                latestRateLimit = searchRL
            }
            for candidate in reviewCandidates {
                if candidatesByKey[candidate.dedupeKey] == nil {
                    candidatesByKey[candidate.dedupeKey] = candidate
                }
            }
        }

        // 3. 缺少 notifications scope 或低频对齐周期时拉取 mentions:@me（通知走邮件返回 200 空列表时仍可兜底发现，配合 updated_at 指纹跳过无变化 PR）
        let shouldRunMentionsSearch = includeMentionsSearchFallback && (notificationsForbidden || request.reconcileNow)
        if shouldRunMentionsSearch {
            let (mentionCandidates, searchRL) = try await searchOpenPRs(
                query: "is:pr is:open mentions:@me",
                triggerKind: .mention,
                fetchLatestComment: true,
                viewerLogin: request.viewerLogin,
                token: token,
                fingerprints: &updatedFingerprints
            )
            if let searchRL, latestRateLimit == nil {
                latestRateLimit = searchRL
            }
            for candidate in mentionCandidates {
                if candidatesByKey[candidate.dedupeKey] == nil {
                    candidatesByKey[candidate.dedupeKey] = candidate
                }
            }
        }

        let sorted = candidatesByKey.values.sorted { $0.item.createdAt > $1.item.createdAt }
        return PollBatch(
            candidates: sorted,
            nextCursor: nextCursor,
            suggestedPollIntervalSeconds: pollInterval,
            diagnosticMessage: diagnostic,
            wasNotModified: wasNotModified && sorted.isEmpty,
            rateLimit: latestRateLimit,
            updatedPRFingerprints: updatedFingerprints
        )
    }

    public func supportedDeliveryModes(for item: CollaborationItem) -> [DeliveryMode] {
        ConnectorCatalog.supportedDeliveryModes(for: item)
    }

    /// 解析 `https://github.com/owner/repo/pull/123` 或 `owner/repo#123`
    public static func parsePullRequestReference(_ input: String) -> (repository: String, number: Int)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let regex = try? NSRegularExpression(pattern: #"github\.com/([A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+)/pull/(\d+)"#, options: [.caseInsensitive]) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range),
               let repoRange = Range(match.range(at: 1), in: trimmed),
               let numRange = Range(match.range(at: 2), in: trimmed),
               let number = Int(trimmed[numRange]) {
                return (String(trimmed[repoRange]), number)
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"^([A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+)#(\d+)$"#) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range),
               let repoRange = Range(match.range(at: 1), in: trimmed),
               let numRange = Range(match.range(at: 2), in: trimmed),
               let number = Int(trimmed[numRange]) {
                return (String(trimmed[repoRange]), number)
            }
        }
        return nil
    }

    /// 按 PR 链接或 `owner/repo#123` 直接拉取真实 GitHub PR（便于手动导入审查与端到端实跑）
    public func fetchPullRequest(reference: String) async throws -> CollaborationItem {
        guard let parsed = Self.parsePullRequestReference(reference) else {
            throw GitHubConnectorError.httpError(statusCode: 400, message: "请输入有效的 GitHub PR 链接或 owner/repo#编号")
        }
        guard let token = await tokenProvider.fetchToken(), !token.isEmpty else {
            throw GitHubConnectorError.missingToken
        }
        let prURL = baseURL.appendingPathComponent("repos/\(parsed.repository)/pulls/\(parsed.number)")
        guard let pr = await fetchPRDetail(url: prURL, token: token) else {
            throw GitHubConnectorError.httpError(statusCode: 404, message: "未能读取 \(parsed.repository)#\(parsed.number)，请确认仓库权限与编号")
        }
        let dedupeKey = "github:\(parsed.repository)#\(pr.number):manual:\(pr.head.sha.prefix(7))"
        return makeCandidate(
            dedupeKey: dedupeKey,
            repo: parsed.repository,
            pr: pr,
            triggerKind: .reviewRequested,
            actor: pr.user.login,
            commentBody: nil
        ).item
    }

    public func deliver(
        output: ExecutionOutput,
        for item: CollaborationItem,
        mode: DeliveryMode,
        context: DeliveryContext
    ) async throws -> DeliveryReceipt {
        try await deliver(
            output: output,
            for: item,
            mode: mode,
            plan: context.plan,
            unifiedDiff: context.unifiedDiff,
            reportsDirectory: context.reportsDirectory
        )
    }

    public func deliver(
        output: ExecutionOutput,
        for item: CollaborationItem,
        mode: DeliveryMode
    ) async throws -> DeliveryReceipt {
        try await deliver(output: output, for: item, mode: mode, context: DeliveryContext())
    }

    /// 完整交付实现：先保存本地 Markdown 报告，再按交付模式提交 GitHub Pending Review 草稿或 Comment（关联 REQ-009, TASK-013）
    public func deliver(
        output: ExecutionOutput,
        for item: CollaborationItem,
        mode: DeliveryMode,
        plan: ExecutionPlan?,
        unifiedDiff: String?,
        reportsDirectory: URL? = nil
    ) async throws -> DeliveryReceipt {
        let markdown = GitHubReviewFormatter.renderLocalMarkdownReport(item: item, output: output, plan: plan)
        let localReportURL = try GitHubReviewFormatter.saveLocalReport(
            markdown: markdown,
            itemID: item.id,
            reportsDirectory: reportsDirectory
        )

        if mode == .localDraftOnly {
            return DeliveryReceipt(
                deliveredMode: .localDraftOnly,
                destinationURL: item.url,
                localReportPath: localReportURL
            )
        }

        guard let token = await tokenProvider.fetchToken(), !token.isEmpty else {
            throw GitHubConnectorError.missingToken
        }

        guard case .codeChange(let code) = item.payload else {
            return DeliveryReceipt(
                deliveredMode: .localDraftOnly,
                destinationURL: item.url,
                localReportPath: localReportURL
            )
        }

        switch output {
        case .codeReview(let review):
            let effectiveDiff: String?
            if let unifiedDiff, !unifiedDiff.isEmpty {
                effectiveDiff = unifiedDiff
            } else {
                effectiveDiff = await fetchPullRequestDiff(repository: code.repository, number: code.number, token: token)
            }

            let payload = GitHubReviewFormatter.buildReviewPayload(
                review: review,
                commitSHA: code.headSHA,
                unifiedDiff: effectiveDiff,
                mode: mode
            )

            let reviewsURL = baseURL.appendingPathComponent("repos/\(code.repository)/pulls/\(code.number)/reviews")
            var req = makeRequest(url: reviewsURL, token: token)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(payload)

            let (respData, resp) = try await transport.data(for: req)
            if resp.statusCode == 401 {
                throw GitHubConnectorError.unauthorized
            }
            if resp.statusCode == 422 {
                let errBody = String(data: respData, encoding: .utf8) ?? ""
                if errBody.lowercased().contains("pending review") {
                    throw GitHubConnectorError.pendingReviewAlreadyExists
                }
                throw GitHubConnectorError.httpError(statusCode: 422, message: errBody)
            }
            guard (200...299).contains(resp.statusCode) else {
                throw GitHubConnectorError.httpError(
                    statusCode: resp.statusCode,
                    message: String(data: respData, encoding: .utf8) ?? ""
                )
            }

            let filesURL = URL(string: "\(item.url.absoluteString)/files") ?? item.url
            return DeliveryReceipt(
                deliveredMode: mode,
                destinationURL: filesURL,
                localReportPath: localReportURL
            )

        case .structuredReply(let reply):
            if mode == .directReply {
                let commentURL = baseURL.appendingPathComponent("repos/\(code.repository)/issues/\(code.number)/comments")
                var req = makeRequest(url: commentURL, token: token)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let bodyPayload = ["body": "\(reply.replyMarkdown)\n\n---\n*Assisted by CollabDock (local AI)*"]
                req.httpBody = try JSONEncoder().encode(bodyPayload)

                let (respData, resp) = try await transport.data(for: req)
                guard (200...299).contains(resp.statusCode) else {
                    throw GitHubConnectorError.httpError(
                        statusCode: resp.statusCode,
                        message: String(data: respData, encoding: .utf8) ?? ""
                    )
                }
            }
            return DeliveryReceipt(
                deliveredMode: mode,
                destinationURL: item.url,
                localReportPath: localReportURL
            )
        }
    }

    private func fetchPullRequestDiff(repository: String, number: Int, token: String) async -> String? {
        let prURL = baseURL.appendingPathComponent("repos/\(repository)/pulls/\(number)")
        var req = makeRequest(url: prURL, token: token)
        req.setValue("application/vnd.github.v3.diff", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await transport.data(for: req), resp.statusCode == 200 else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Private Hydration Helpers

    private func hydrateFromNotificationThread(
        _ thread: GHNotificationThread,
        triggerKind: TriggerKind,
        viewerLogin: String?,
        token: String
    ) async -> PolledCollaborationCandidate? {
        guard let subjectURLStr = thread.subject.url,
              let prAPIURL = URL(string: subjectURLStr) else {
            return nil
        }
        guard let pr = await fetchPRDetail(url: prAPIURL, token: token) else {
            return nil
        }

        let repo = thread.repository.fullName
        var commentBody: String?
        var actor = pr.user.login
        var revisionKey: String
        var viewerIsReviewer = false

        if triggerKind == .reviewRequested {
            // Re-request review 以 pr.head.sha 为去重基线，并在本人提交过 review 后再次被请求时追加请求时间（与 Search 通道保持一致）
            revisionKey = await resolveReviewRequestedRevisionKey(
                repo: repo,
                number: pr.number,
                headSHA: pr.head.sha,
                viewerLogin: viewerLogin,
                token: token
            )
        } else {
            revisionKey = thread.updatedAt
            if let latestCommentStr = thread.subject.latestCommentURL,
               let commentURL = URL(string: latestCommentStr),
               latestCommentStr != subjectURLStr,
               let comment = await fetchSingleComment(url: commentURL, token: token) {
                commentBody = comment.body
                actor = comment.user.login
                revisionKey = "c\(comment.id)"
            }
            if triggerKind == .mention || triggerKind == .threadReply {
                viewerIsReviewer = await resolveViewerIsReviewer(
                    repo: repo,
                    pr: pr,
                    viewerLogin: viewerLogin,
                    token: token
                )
            }
        }

        let dedupeKey = "github:\(repo)#\(pr.number):\(triggerKind.rawValue):\(revisionKey)"
        return makeCandidate(
            dedupeKey: dedupeKey,
            repo: repo,
            pr: pr,
            triggerKind: triggerKind,
            actor: actor,
            commentBody: commentBody,
            viewerIsReviewer: viewerIsReviewer
        )
    }

    private func searchOpenPRs(
        query: String,
        triggerKind: TriggerKind,
        fetchLatestComment: Bool,
        viewerLogin: String?,
        token: String,
        fingerprints: inout [String: String]
    ) async throws -> ([PolledCollaborationCandidate], RateLimitSnapshot?) {
        var comps = URLComponents(url: baseURL.appendingPathComponent("search/issues"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: "10")
        ]
        guard let url = comps?.url else { return ([], nil) }

        let req = makeRequest(url: url, token: token)
        let (data, resp) = try await transport.data(for: req)
        let rl = Self.parseRateLimit(from: resp)

        if let retryAfter = Self.detectRateLimitBackoff(response: resp, rateLimit: rl) {
            throw GitHubConnectorError.rateLimited(retryAfterSeconds: retryAfter)
        }
        if resp.statusCode == 401 {
            throw GitHubConnectorError.unauthorized
        }
        guard resp.statusCode == 200 else {
            return ([], rl)
        }

        let searchResp = (try? JSONDecoder().decode(GHSearchResponse.self, from: data)) ?? GHSearchResponse(items: [])
        var results: [PolledCollaborationCandidate] = []

        for issue in searchResp.items {
            guard let prAPIURLStr = issue.pullRequest?.url,
                  let prAPIURL = URL(string: prAPIURLStr),
                  let repo = Self.extractRepoFullName(fromRepositoryURL: issue.repositoryURL) else {
                continue
            }

            // updated_at 指纹命中：PR 毫无变化时跳过 /pulls 与 /comments 水合，节省 95%+ 配额
            let fpKey = "\(repo)#\(issue.number):\(triggerKind.rawValue)"
            if let updatedAt = issue.updatedAt, !updatedAt.isEmpty, fingerprints[fpKey] == updatedAt {
                continue
            }

            guard let pr = await fetchPRDetail(url: prAPIURL, token: token) else {
                continue
            }

            if let updatedAt = issue.updatedAt ?? pr.updatedAt {
                fingerprints[fpKey] = updatedAt
            }

            var commentBody: String?
            var actor = pr.user.login
            var revisionKey = pr.head.sha
            var viewerIsReviewer = false

            if fetchLatestComment, let commentsURLStr = issue.commentsURL, let commentsURL = URL(string: commentsURLStr) {
                if let latest = await fetchLatestIssueComment(url: commentsURL, token: token) {
                    commentBody = latest.body
                    actor = latest.user.login
                    revisionKey = "c\(latest.id)"
                } else if let prBody = issue.body, !prBody.isEmpty {
                    commentBody = prBody
                    revisionKey = "prbody-\(pr.head.sha)"
                }
            } else if triggerKind == .reviewRequested {
                revisionKey = await resolveReviewRequestedRevisionKey(
                    repo: repo,
                    number: pr.number,
                    headSHA: pr.head.sha,
                    viewerLogin: viewerLogin,
                    token: token
                )
            }

            if triggerKind == .mention || triggerKind == .threadReply {
                viewerIsReviewer = await resolveViewerIsReviewer(
                    repo: repo,
                    pr: pr,
                    viewerLogin: viewerLogin,
                    token: token
                )
            }

            let dedupeKey = "github:\(repo)#\(pr.number):\(triggerKind.rawValue):\(revisionKey)"
            results.append(
                makeCandidate(
                    dedupeKey: dedupeKey,
                    repo: repo,
                    pr: pr,
                    triggerKind: triggerKind,
                    actor: actor,
                    commentBody: commentBody,
                    viewerIsReviewer: viewerIsReviewer
                )
            )
        }
        return (results, rl)
    }

    private func resolveReviewRequestedRevisionKey(
        repo: String,
        number: Int,
        headSHA: String,
        viewerLogin: String?,
        token: String
    ) async -> String {
        guard let viewer = viewerLogin?.trimmingCharacters(in: .whitespacesAndNewlines),
              !viewer.isEmpty else {
            return headSHA
        }
        guard let events = await fetchIssueTimeline(repo: repo, number: number, token: token),
              let reRequestAt = Self.reRequestTimestampAfterLatestReview(in: events, viewerLogin: viewer) else {
            return headSHA
        }
        return "\(headSHA)@\(reRequestAt)"
    }

    private static func reRequestTimestampAfterLatestReview(
        in events: [GHTimelineEvent],
        viewerLogin: String
    ) -> String? {
        let target = viewerLogin.lowercased()
        var latestReviewDate: Date?

        for event in events where event.event?.lowercased() == "reviewed" {
            guard event.user?.login?.lowercased() == target else { continue }
            if event.state?.lowercased() == "pending" { continue }
            guard let submittedStr = event.submittedAt ?? event.createdAt,
                  let submittedDate = parseISO8601(submittedStr) else {
                continue
            }
            if latestReviewDate == nil || submittedDate > latestReviewDate! {
                latestReviewDate = submittedDate
            }
        }

        guard let latestReviewDate else { return nil }

        var latestReRequest: (date: Date, raw: String)?
        for event in events where event.event?.lowercased() == "review_requested" {
            guard event.requestedReviewer?.login?.lowercased() == target else { continue }
            guard let raw = event.createdAt,
                  let date = parseISO8601(raw),
                  date > latestReviewDate else {
                continue
            }
            if latestReRequest == nil || date > latestReRequest!.date {
                latestReRequest = (date, raw)
            }
        }

        return latestReRequest?.raw
    }

    /// 判定当前用户是否为该 PR 的 reviewer（仍在 `requested_reviewers` 中，或已在 timeline 提交过非 pending 的 review）
    private func resolveViewerIsReviewer(
        repo: String,
        pr: GHPullRequestDetail,
        viewerLogin: String?,
        token: String
    ) async -> Bool {
        guard let viewer = viewerLogin?.trimmingCharacters(in: .whitespacesAndNewlines),
              !viewer.isEmpty else {
            return false
        }
        let target = viewer.lowercased()
        if let requested = pr.requestedReviewers,
           requested.contains(where: { $0.login?.lowercased() == target }) {
            return true
        }
        guard let events = await fetchIssueTimeline(repo: repo, number: pr.number, token: token) else {
            return false
        }
        return Self.hasSubmittedReview(in: events, viewerLogin: viewer)
    }

    private static func hasSubmittedReview(
        in events: [GHTimelineEvent],
        viewerLogin: String
    ) -> Bool {
        let target = viewerLogin.lowercased()
        return events.contains { event in
            guard event.event?.lowercased() == "reviewed",
                  event.user?.login?.lowercased() == target else {
                return false
            }
            return event.state?.lowercased() != "pending"
        }
    }

    private func makeCandidate(
        dedupeKey: String,
        repo: String,
        pr: GHPullRequestDetail,
        triggerKind: TriggerKind,
        actor: String,
        commentBody: String?,
        viewerIsReviewer: Bool = false
    ) -> PolledCollaborationCandidate {
        let prURL = URL(string: pr.htmlURL) ?? URL(string: "https://github.com/\(repo)/pull/\(pr.number)")!
        let createdAt = Self.parseISO8601(pr.updatedAt ?? pr.createdAt) ?? Date()

        let event = IncomingCollaborationEvent(
            platform: .github,
            scope: repo,
            externalRef: "#\(pr.number)",
            triggerKind: triggerKind,
            actor: actor,
            isDraftItem: pr.draft ?? false,
            body: commentBody,
            viewerIsReviewer: viewerIsReviewer
        )

        let item = CollaborationItem(
            id: dedupeKey,
            platform: .github,
            itemKind: .pullRequest,
            scope: repo,
            externalRef: "#\(pr.number)",
            title: pr.title,
            url: prURL,
            author: pr.user.login,
            triggeredBy: actor,
            triggerKind: triggerKind,
            triggerBody: commentBody,
            payload: .codeChange(
                CodeChangePayload(
                    repository: repo,
                    number: pr.number,
                    baseRef: pr.base.ref,
                    headRef: pr.head.ref,
                    headSHA: pr.head.sha,
                    additions: pr.additions ?? 0,
                    deletions: pr.deletions ?? 0,
                    changedFiles: pr.changedFiles ?? 0,
                    isDraft: pr.draft ?? false
                )
            ),
            createdAt: createdAt
        )

        return PolledCollaborationCandidate(dedupeKey: dedupeKey, event: event, item: item)
    }

    private func fetchPRDetail(url: URL, token: String) async -> GHPullRequestDetail? {
        let req = makeRequest(url: url, token: token)
        guard let (data, resp) = try? await transport.data(for: req), resp.statusCode == 200 else {
            return nil
        }
        return try? JSONDecoder().decode(GHPullRequestDetail.self, from: data)
    }

    private func fetchSingleComment(url: URL, token: String) async -> GHComment? {
        let req = makeRequest(url: url, token: token)
        guard let (data, resp) = try? await transport.data(for: req), resp.statusCode == 200 else {
            return nil
        }
        return try? JSONDecoder().decode(GHComment.self, from: data)
    }

    private func fetchLatestIssueComment(url: URL, token: String) async -> GHComment? {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "per_page", value: "20")
        ]
        guard let finalURL = comps?.url else { return nil }
        let req = makeRequest(url: finalURL, token: token)
        guard let (data, resp) = try? await transport.data(for: req), resp.statusCode == 200 else {
            return nil
        }
        let comments = (try? JSONDecoder().decode([GHComment].self, from: data)) ?? []
        return comments.last
    }

    private func fetchIssueTimeline(repo: String, number: Int, token: String) async -> [GHTimelineEvent]? {
        let base = baseURL.appendingPathComponent("repos/\(repo)/issues/\(number)/timeline")
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "per_page", value: "100")
        ]
        guard let finalURL = comps?.url else { return nil }
        let req = makeRequest(url: finalURL, token: token)
        guard let (data, resp) = try? await transport.data(for: req), resp.statusCode == 200 else {
            return nil
        }
        return try? JSONDecoder().decode([GHTimelineEvent].self, from: data)
    }

    private func makeRequest(url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("CollabDock/0.1", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func mapNotificationReason(_ reason: String) -> TriggerKind? {
        switch reason {
        case "mention": return .mention
        case "review_requested": return .reviewRequested
        case "team_mention": return .teamMention
        case "assign": return .assigned
        default: return nil
        }
    }

    public static func extractRepoFullName(fromRepositoryURL urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3, parts[0] == "repos" else { return nil }
        return "\(parts[1])/\(parts[2])"
    }

    public static func parseRateLimit(from response: HTTPURLResponse) -> RateLimitSnapshot? {
        guard let limitStr = response.value(forHTTPHeaderField: "X-RateLimit-Limit"),
              let remStr = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
              let limit = Int(limitStr),
              let remaining = Int(remStr) else {
            return nil
        }
        let resetDate: Date?
        if let resetStr = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let epoch = TimeInterval(resetStr) {
            resetDate = Date(timeIntervalSince1970: epoch)
        } else {
            resetDate = nil
        }
        return RateLimitSnapshot(limit: limit, remaining: remaining, resetAt: resetDate)
    }

    public static func detectRateLimitBackoff(
        response: HTTPURLResponse,
        rateLimit: RateLimitSnapshot?,
        now: Date = Date()
    ) -> Int? {
        guard response.statusCode == 429 || response.statusCode == 403 else { return nil }
        if let retryHeader = response.value(forHTTPHeaderField: "Retry-After"),
           let secs = Int(retryHeader), secs > 0 {
            return secs
        }
        if response.statusCode == 429 {
            return 120
        }
        if let rateLimit, rateLimit.remaining == 0 {
            if let resetAt = rateLimit.resetAt {
                return max(60, Int(ceil(resetAt.timeIntervalSince(now))))
            }
            return 300
        }
        return nil
    }

    private static func parseISO8601(_ str: String?) -> Date? {
        guard let str else { return nil }
        let formatter = ISO8601DateFormatter()
        if let d = formatter.date(from: str) {
            return d
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - GraphQL 批量同步活跃 PR 状态（Approve / Merged / Closed 自动归档，Request Changes 保留跟进，关联 ITER-017）

    public struct PRRemoteReviewEntry: Equatable, Sendable {
        public let state: String
        public let authorLogin: String
        public let submittedAt: Date?
        public let commitOID: String?

        public init(state: String, authorLogin: String, submittedAt: Date?, commitOID: String?) {
            self.state = state
            self.authorLogin = authorLogin
            self.submittedAt = submittedAt
            self.commitOID = commitOID
        }
    }

    public struct PRRemoteStatusSnapshot: Equatable, Sendable {
        public let repository: String
        public let number: Int
        public let state: String
        public let merged: Bool
        public let headRefOID: String?
        public let reviews: [PRRemoteReviewEntry]

        public init(
            repository: String,
            number: Int,
            state: String,
            merged: Bool,
            headRefOID: String?,
            reviews: [PRRemoteReviewEntry]
        ) {
            self.repository = repository
            self.number = number
            self.state = state
            self.merged = merged
            self.headRefOID = headRefOID
            self.reviews = reviews
        }
    }

    public struct PRSyncEvaluation: Equatable, Sendable {
        public let completionReason: TaskCompletionReason?
        public let latestViewerVerdict: String?

        public init(completionReason: TaskCompletionReason?, latestViewerVerdict: String?) {
            self.completionReason = completionReason
            self.latestViewerVerdict = latestViewerVerdict
        }
    }

    /// 一次 GraphQL 请求批量查询收件箱中全部活跃 GitHub PR 的合并/关闭状态与本人最新 Review 结论（收件箱为空时零请求）
    public func fetchPRStatusSnapshots(
        targets: [PRStateReconciler.Target]
    ) async throws -> PRStatusBatchResult {
        guard !targets.isEmpty,
              let token = await tokenProvider.fetchToken(),
              !token.isEmpty else {
            return PRStatusBatchResult()
        }

        // 去重并做严格的 owner/name 白名单校验
        var uniqueTargets: [(key: String, owner: String, name: String, number: Int, repository: String)] = []
        var seen: Set<String> = []
        let validSegment = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for t in targets {
            let parts = t.repository.split(separator: "/").map(String.init)
            guard parts.count == 2,
                  parts[0].unicodeScalars.allSatisfy({ validSegment.contains($0) }),
                  parts[1].unicodeScalars.allSatisfy({ validSegment.contains($0) }),
                  t.number > 0 else {
                continue
            }
            let normalizedRepo = "\(parts[0])/\(parts[1])"
            let key = PRStateReconciler.key(repository: normalizedRepo, number: t.number)
            if seen.insert(key).inserted {
                uniqueTargets.append((key, parts[0], parts[1], t.number, normalizedRepo))
            }
        }
        guard !uniqueTargets.isEmpty else { return PRStatusBatchResult() }

        var queryFields: [String] = ["viewer { login }"]
        for (idx, t) in uniqueTargets.prefix(25).enumerated() {
            queryFields.append("""
            pr\(idx): repository(owner: "\(t.owner)", name: "\(t.name)") {
              pullRequest(number: \(t.number)) {
                state
                merged
                headRefOid
                reviews(last: 20) {
                  nodes {
                    state
                    submittedAt
                    author { login }
                    commit { oid }
                  }
                }
              }
            }
            """)
        }

        let query = "query {\n" + queryFields.joined(separator: "\n") + "\n}"
        let graphqlURL = baseURL.appendingPathComponent("graphql")
        var req = makeRequest(url: graphqlURL, token: token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": query]) else {
            return PRStatusBatchResult()
        }
        req.httpBody = body

        guard let (data, resp) = try? await transport.data(for: req),
              (200...299).contains(resp.statusCode) else {
            return PRStatusBatchResult()
        }
        let parsed = Self.parseGraphQLPRStatusResponse(
            data: data,
            targets: uniqueTargets.prefix(25).map { (key: $0.key, repository: $0.repository, number: $0.number) }
        )
        return PRStatusBatchResult(viewerLogin: parsed.viewerLogin, snapshots: parsed.snapshots)
    }

    public static func parseGraphQLPRStatusResponse(
        data: Data,
        targets: [(key: String, repository: String, number: Int)]
    ) -> (viewerLogin: String?, snapshots: [String: PRRemoteStatusSnapshot]) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataObj = root["data"] as? [String: Any] else {
            return (nil, [:])
        }
        let viewerLogin = (dataObj["viewer"] as? [String: Any])?["login"] as? String
        var snapshots: [String: PRRemoteStatusSnapshot] = [:]

        for (idx, target) in targets.enumerated() {
            guard let repoObj = dataObj["pr\(idx)"] as? [String: Any],
                  let prObj = repoObj["pullRequest"] as? [String: Any] else {
                continue
            }
            let state = (prObj["state"] as? String ?? "OPEN").uppercased()
            let merged = (prObj["merged"] as? Bool) ?? (state == "MERGED")
            let headRefOID = prObj["headRefOid"] as? String

            let reviewNodes = ((prObj["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            let reviews: [PRRemoteReviewEntry] = reviewNodes.compactMap { node in
                guard let rState = node["state"] as? String,
                      let authorLogin = (node["author"] as? [String: Any])?["login"] as? String else {
                    return nil
                }
                let submitted = parseISO8601(node["submittedAt"] as? String)
                let oid = (node["commit"] as? [String: Any])?["oid"] as? String
                return PRRemoteReviewEntry(
                    state: rState.uppercased(),
                    authorLogin: authorLogin,
                    submittedAt: submitted,
                    commitOID: oid
                )
            }

            snapshots[target.key] = PRRemoteStatusSnapshot(
                repository: target.repository,
                number: target.number,
                state: state,
                merged: merged,
                headRefOID: headRefOID,
                reviews: reviews
            )
        }
        return (viewerLogin, snapshots)
    }

    /// 精确判定 PR 是否应自动归档：仅 `APPROVED`（对应本轮 commit 或入箱后提交）与 `MERGED / CLOSED` 自动归档；`CHANGES_REQUESTED` 保留在收件箱继续跟进
    public static func evaluatePRAutoCompletion(
        item: CollaborationItem,
        snapshot: PRRemoteStatusSnapshot,
        viewerLogin: String
    ) -> PRSyncEvaluation {
        if snapshot.merged || snapshot.state == "MERGED" {
            return PRSyncEvaluation(completionReason: .prMerged, latestViewerVerdict: "MERGED")
        }
        if snapshot.state == "CLOSED" {
            return PRSyncEvaluation(completionReason: .prClosed, latestViewerVerdict: "CLOSED")
        }

        let targetLogin = viewerLogin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !targetLogin.isEmpty else {
            return PRSyncEvaluation(completionReason: nil, latestViewerVerdict: nil)
        }

        // 仅取当前用户已提交的决定性结论（忽略 PENDING 草稿与普通 COMMENTED，保留 DISMISSED 以防旧批准被驳回后误判）
        let decisiveStates: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]
        let myReviews = snapshot.reviews
            .filter { $0.authorLogin.lowercased() == targetLogin && decisiveStates.contains($0.state) }
            .sorted { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }

        guard let latest = myReviews.last else {
            return PRSyncEvaluation(completionReason: nil, latestViewerVerdict: nil)
        }

        let itemHeadSHA: String? = {
            if case .codeChange(let code) = item.payload {
                return code.headSHA.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }()

        // 同提交复审（本轮 headSHA 与上一轮已审查 SHA 相同）：不可按 commit OID 匹配，否则会继承上一轮在同 SHA 上留下的旧 verdict
        let isSameCommitFollowUp: Bool = {
            guard let prev = item.previousReview else { return false }
            let prevSHA = prev.reviewedHeadSHA.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prevSHA.isEmpty, let sha = itemHeadSHA, !sha.isEmpty else { return false }
            return prevSHA.lowercased() == sha.lowercased()
        }()

        // 防多轮复审误杀：
        // - 同提交复审：仅接受晚于上一轮审查且不早于本轮入箱时间的新 review
        // - 其余情况：命中当前轮次 commit 或提交时间不早于本轮入箱时间
        let matchesCurrentRound: Bool = {
            if isSameCommitFollowUp {
                guard let submitted = latest.submittedAt else { return false }
                if let prevReviewedAt = item.previousReview?.reviewedAt, submitted <= prevReviewedAt {
                    return false
                }
                return submitted >= item.createdAt
            }
            if let sha = itemHeadSHA, !sha.isEmpty, let oid = latest.commitOID, oid.lowercased() == sha.lowercased() {
                return true
            }
            if let liveHead = snapshot.headRefOID, !liveHead.isEmpty, let oid = latest.commitOID,
               oid.lowercased() == liveHead.lowercased(),
               (itemHeadSHA?.isEmpty ?? true) || itemHeadSHA?.lowercased() == liveHead.lowercased() {
                return true
            }
            if let submitted = latest.submittedAt, submitted >= item.createdAt.addingTimeInterval(-60) {
                return true
            }
            return false
        }()

        guard matchesCurrentRound else {
            return PRSyncEvaluation(completionReason: nil, latestViewerVerdict: nil)
        }

        if latest.state == "APPROVED" {
            return PRSyncEvaluation(completionReason: .prApproved, latestViewerVerdict: "APPROVED")
        }
        if latest.state == "CHANGES_REQUESTED" {
            // Request Changes 不自动完成，保留在收件箱继续跟进
            return PRSyncEvaluation(completionReason: nil, latestViewerVerdict: "CHANGES_REQUESTED")
        }
        return PRSyncEvaluation(completionReason: nil, latestViewerVerdict: nil)
    }
}

// MARK: - GitHub REST API DTOs

private struct GHNotificationThread: Decodable {
    let id: String
    let reason: String
    let updatedAt: String
    let subject: Subject
    let repository: Repository

    enum CodingKeys: String, CodingKey {
        case id, reason, subject, repository
        case updatedAt = "updated_at"
    }

    struct Subject: Decodable {
        let title: String
        let url: String?
        let latestCommentURL: String?
        let type: String

        enum CodingKeys: String, CodingKey {
            case title, url, type
            case latestCommentURL = "latest_comment_url"
        }
    }

    struct Repository: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }
}

private struct GHSearchResponse: Decodable {
    let items: [GHSearchIssueItem]
}

private struct GHSearchIssueItem: Decodable {
    let number: Int
    let title: String
    let body: String?
    let updatedAt: String?
    let repositoryURL: String
    let commentsURL: String?
    let pullRequest: PullRequestLinks?

    enum CodingKeys: String, CodingKey {
        case number, title, body
        case updatedAt = "updated_at"
        case repositoryURL = "repository_url"
        case commentsURL = "comments_url"
        case pullRequest = "pull_request"
    }

    struct PullRequestLinks: Decodable {
        let url: String?
    }
}

private struct GHPullRequestDetail: Decodable {
    let number: Int
    let title: String
    let htmlURL: String
    let draft: Bool?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let createdAt: String?
    let updatedAt: String?
    let user: GHUser
    let requestedReviewers: [GHOptionalUser]?
    let base: GHRef
    let head: GHRef

    enum CodingKeys: String, CodingKey {
        case number, title, draft, additions, deletions, user, base, head
        case htmlURL = "html_url"
        case changedFiles = "changed_files"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case requestedReviewers = "requested_reviewers"
    }
}

private struct GHUser: Decodable {
    let login: String
}

private struct GHRef: Decodable {
    let ref: String
    let sha: String
}

private struct GHComment: Decodable {
    let id: Int
    let body: String
    let user: GHUser
}

private struct GHOptionalUser: Decodable {
    let login: String?
}

private struct GHTimelineEvent: Decodable {
    let event: String?
    let createdAt: String?
    let submittedAt: String?
    let state: String?
    let user: GHOptionalUser?
    let requestedReviewer: GHOptionalUser?

    enum CodingKeys: String, CodingKey {
        case event, state, user
        case createdAt = "created_at"
        case submittedAt = "submitted_at"
        case requestedReviewer = "requested_reviewer"
    }
}
