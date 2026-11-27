#if DEBUG
import AppKit
import SwiftUI
import CollabDockCore

@MainActor
public enum PreviewSnapshotter {
    public static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--snapshot-dir"), idx + 1 < args.count else {
            return
        }
        let outDir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let langArg: String? = {
            if let lIdx = args.firstIndex(of: "--snapshot-lang"), lIdx + 1 < args.count {
                return args[lIdx + 1].lowercased()
            }
            return nil
        }()

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        switch langArg {
        case "en":
            CoreL10n.overrideLanguage = .en
            renderAll(to: outDir, language: .en)
        case "zh-hans", "zh":
            CoreL10n.overrideLanguage = .zhHans
            renderAll(to: outDir, language: .zhHans)
        case "system":
            CoreL10n.overrideLanguage = nil
            renderAll(to: outDir, language: CoreL10n.currentLanguage)
        default:
            CoreL10n.overrideLanguage = .zhHans
            renderAll(to: outDir, language: .zhHans)

            let enDir = outDir.appendingPathComponent("en", isDirectory: true)
            try? FileManager.default.createDirectory(at: enDir, withIntermediateDirectories: true)
            CoreL10n.overrideLanguage = .en
            renderAll(to: enDir, language: .en)
        }
        CoreL10n.overrideLanguage = nil
        exit(0)
    }

    private static func renderAll(to dir: URL, language: ResolvedLanguage) {
        let isZH = (language == .zhHans)

        let inboxLight = AppCoordinator(previewMode: true)
        render(
            view: MenuBarContentView(coordinator: inboxLight),
            scheme: .light,
            height: 416,
            language: language,
            to: dir.appendingPathComponent("inbox-light.png")
        )

        let inboxDark = AppCoordinator(previewMode: true)
        render(
            view: MenuBarContentView(coordinator: inboxDark),
            scheme: .dark,
            height: 416,
            language: language,
            to: dir.appendingPathComponent("inbox-dark.png")
        )

        let ghDetailLight = AppCoordinator(previewMode: true)
        render(
            view: MenuBarContentView(coordinator: ghDetailLight, initialDetailItemID: "demo-gh-482"),
            scheme: .light,
            height: CDTheme.detailHeight,
            language: language,
            to: dir.appendingPathComponent("detail-github-light.png")
        )

        let feishuDetailDark = AppCoordinator(previewMode: true)
        feishuDetailDark.settings.defaultEngine = .lody
        feishuDetailDark.settings.lodyConfig.defaultAgentConfig = "lody-antigravity"
        feishuDetailDark.setPreferredLodyModel("gemini-4-neon", forAgentConfig: "lody-antigravity")
        render(
            view: MenuBarContentView(coordinator: feishuDetailDark, initialDetailItemID: "demo-feishu-oncall"),
            scheme: .dark,
            height: CDTheme.detailHeight,
            language: language,
            to: dir.appendingPathComponent("detail-lody-dark.png")
        )

        // 复审模式确认画布预览（续聊原 Lody 会话 + 增量 Diff）
        let reReviewCoord = AppCoordinator(previewMode: true)
        reReviewCoord.settings.defaultEngine = .lody
        reReviewCoord.settings.lodyConfig.defaultAgentConfig = "lody-antigravity"
        reReviewCoord.setPreferredLodyModel("gemini-4-neon", forAgentConfig: "lody-antigravity")
        if let idx = reReviewCoord.items.firstIndex(where: { $0.id == "demo-gh-482" }) {
            reReviewCoord.items[idx].previousReview = PreviousReviewContext(
                previousItemID: "demo-gh-482-r1",
                reviewedHeadSHA: "99aabb1",
                reviewedAt: Date().addingTimeInterval(-3600),
                engine: .lody,
                sessionID: "ses_r1_demo",
                summarySnippet: isZH ? "发现 1 处并发刷新竞态" : "Found 1 concurrent refresh race condition",
                reviewRound: 1
            )
            reReviewCoord.items[idx].reviewRound = 2
        }
        render(
            view: MenuBarContentView(coordinator: reReviewCoord, initialDetailItemID: "demo-gh-482"),
            scheme: .dark,
            height: CDTheme.detailHeight,
            language: language,
            to: dir.appendingPathComponent("detail-rereview-lody-dark.png")
        )

        let settingsCoord = AppCoordinator(previewMode: true)
        settingsCoord.settings.defaultEngine = .lody
        settingsCoord.settings.lodyConfig.defaultAgentConfig = "lody-antigravity"
        settingsCoord.setPreferredLodyModel("gemini-4-neon", forAgentConfig: "lody-antigravity")
        renderWindow(
            view: SettingsView(coordinator: settingsCoord, initialTab: .engines),
            scheme: .light,
            width: 684,
            height: 580,
            language: language,
            to: dir.appendingPathComponent("settings-lody-engines-light.png")
        )

        let claudeSettingsCoord = AppCoordinator(previewMode: true)
        claudeSettingsCoord.settings.defaultEngine = .claudeCode
        renderWindow(
            view: SettingsView(coordinator: claudeSettingsCoord, initialTab: .engines),
            scheme: .light,
            width: 684,
            height: 580,
            language: language,
            to: dir.appendingPathComponent("settings-claude-engines-light.png")
        )

        renderWindow(
            view: SettingsView(coordinator: settingsCoord, initialTab: .workspaces),
            scheme: .light,
            width: 684,
            height: 580,
            language: language,
            to: dir.appendingPathComponent("settings-workspaces-light.png")
        )

        let statsPopoverDark = AppCoordinator(previewMode: true)
        render(
            view: MenuBarContentView(coordinator: statsPopoverDark, initialShowStats: true),
            scheme: .dark,
            height: 524,
            language: language,
            to: dir.appendingPathComponent("stats-popover-dark.png")
        )

        renderWindow(
            view: SettingsView(coordinator: settingsCoord, initialTab: .stats),
            scheme: .light,
            width: 704,
            height: 600,
            language: language,
            to: dir.appendingPathComponent("settings-stats-light.png")
        )

        // ITER-015：精简空态收件箱 & 已完成归档页预览
        let emptyInboxCoord = AppCoordinator(previewMode: true)
        emptyInboxCoord.items.removeAll()
        render(
            view: MenuBarContentView(coordinator: emptyInboxCoord),
            scheme: .light,
            height: 360,
            language: language,
            to: dir.appendingPathComponent("inbox-empty-light.png")
        )

        let completedCoord = AppCoordinator(previewMode: true)
        if let firstID = completedCoord.items.first?.id {
            completedCoord.markItemCompleted(id: firstID)
        }
        if let lastID = completedCoord.items.last?.id {
            completedCoord.markItemCompleted(id: lastID)
        }
        completedCoord.selectedTab = .completed
        render(
            view: MenuBarContentView(coordinator: completedCoord),
            scheme: .light,
            height: 360,
            language: language,
            to: dir.appendingPathComponent("completed-light.png")
        )

        renderMenuBarIconsSheet(to: dir.appendingPathComponent("menubar-icons-peekcat.png"), language: language)
        renderInboxShowcase(to: dir, language: language)
    }

    /// 生成覆盖收件箱全部类型与状态的 8 张完整视觉测试截图
    private static func renderInboxShowcase(to dir: URL, language: ResolvedLanguage) {
        let isZH = (language == .zhHans)
        let previewEnv = EnvironmentSnapshot(
            resolvedPATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            git: CLIProbeStatus(name: "git", isInstalled: true, executablePath: "/usr/bin/git", version: "2.48"),
            gh: CLIProbeStatus(name: "gh", isInstalled: true, executablePath: "/opt/homebrew/bin/gh", version: "2.65"),
            // 四个引擎都标记为已安装，否则确认卡片里的引擎格子会显示为禁用
            engines: [
                .claudeCode: CLIProbeStatus(name: "claude", isInstalled: true, executablePath: "/opt/homebrew/bin/claude", version: "2.1"),
                .codex: CLIProbeStatus(name: "codex", isInstalled: true, executablePath: "/opt/homebrew/bin/codex", version: "0.98"),
                .antigravity: CLIProbeStatus(name: "agy", isInstalled: true, executablePath: "/opt/homebrew/bin/agy", version: "1.4"),
                .lody: CLIProbeStatus(name: "lody", isInstalled: true, executablePath: "/opt/homebrew/bin/lody", version: "0.9")
            ],
            githubAuth: GitHubAuthSnapshot(
                isAuthenticated: true,
                username: "alex-dev",
                displayName: "Alex",
                avatarURL: nil,
                tokenSource: .ghCLI,
                scopes: ["repo", "notifications"],
                hasNotificationsScope: true
            ),
            discoveredModels: [:]
        )

        func makeBaseCoord() -> AppCoordinator {
            let c = AppCoordinator(previewMode: true)
            c.environment = previewEnv
            // README 演示以本机直连的 Codex CLI 为主
            c.settings.defaultEngine = .codex
            c.settings.lodyConfig.defaultAgentConfig = "lody-antigravity"
            c.setPreferredLodyModel("gemini-4-neon", forAgentConfig: "lody-antigravity")
            c.setPreferredLodyMode("plan", forAgentConfig: "lody-antigravity")
            if !isZH {
                c.settings.presets = [
                    TaskPreset(
                        id: "code-review-general",
                        name: "Review this PR",
                        category: .codeReview,
                        promptInstructions: "Please review this PR."
                    )
                ]
            }
            return c
        }

        // 1. 空态收件箱（亮色）
        let s1 = makeBaseCoord()
        s1.items.removeAll()
        render(
            view: MenuBarContentView(coordinator: s1),
            scheme: .light,
            height: 350,
            language: language,
            to: dir.appendingPathComponent("showcase-01-empty-light.png")
        )

        // 2. 待确认多平台列表（含 @mention、review_requested、第 2 轮复审徽章、飞书群聊话题）
        let s2 = makeBaseCoord()
        s2.items.removeAll { $0.status != .pendingConfirmation }
        if let idx = s2.items.firstIndex(where: { $0.id == "demo-gh-482" }) {
            s2.items[idx].previousReview = PreviousReviewContext(
                previousItemID: "demo-gh-482-r1",
                reviewedHeadSHA: "99aabb1",
                reviewedAt: Date().addingTimeInterval(-3600),
                engine: .lody,
                sessionID: "ses_r1",
                summarySnippet: isZH ? "发现 1 处并发竞态" : "Found 1 concurrency race condition",
                reviewRound: 1
            )
            s2.items[idx].reviewRound = 2
        }
        render(
            view: MenuBarContentView(coordinator: s2),
            scheme: .light,
            height: 390,
            language: language,
            to: dir.appendingPathComponent("showcase-02-pending-multiplatform-light.png")
        )

        // 3. 正在执行 + Lody 后台「审查中」+ 执行失败（暗色）
        let s3 = makeBaseCoord()
        s3.items = [
            CollaborationItem(
                id: "sc-running-local",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/web",
                externalRef: "#4812",
                title: "perf(query): batch formula dependency lookups",
                url: URL(string: "https://github.com/acme/web/pull/4812")!,
                author: "alice",
                triggeredBy: "alice",
                triggerKind: .mention,
                payload: .codeChange(CodeChangePayload(repository: "acme/web", number: 4812, baseRef: "develop", headRef: "perf/formula", headSHA: "aa11", additions: 210, deletions: 45, changedFiles: 7)),
                status: .running,
                progressMessage: isZH
                    ? "Claude Opus 正在只读审查 Diff (已读 5/7 文件)..."
                    : "Claude Opus reviewing diff read-only (5/7 files read)..."
            ),
            CollaborationItem(
                id: "sc-failed",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/infra",
                externalRef: "#1024",
                title: "chore(helm): tighten gateway rate-limit burst",
                url: URL(string: "https://github.com/acme/infra/pull/1024")!,
                author: "ops-bot",
                triggeredBy: "bob",
                triggerKind: .reviewRequested,
                payload: .codeChange(CodeChangePayload(repository: "acme/infra", number: 1024, baseRef: "main", headRef: "chore/helm", headSHA: "bb22", additions: 18, deletions: 4, changedFiles: 2)),
                status: .failed,
                errorMessage: isZH
                    ? "本地项目缺少目标分支引用，请确认 git fetch 可用或先切换为「直用主目录」重试。"
                    : "Target branch ref not found in the local project. Check git fetch or switch to \"Main Dir\" and retry."
            ),
            CollaborationItem(
                id: "sc-lody-running",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/web",
                externalRef: "#4800",
                title: "fix(trust-safety): page chat moderation by cursor and drop the config hint",
                url: URL(string: "https://github.com/acme/web/pull/4800")!,
                author: "carol",
                triggeredBy: "carol",
                triggerKind: .reviewRequested,
                payload: .codeChange(CodeChangePayload(repository: "acme/web", number: 4800, baseRef: "develop", headRef: "fix/chat-moderation-followups", headSHA: "0762c65", additions: 534, deletions: 204, changedFiles: 28)),
                status: .draftReady,
                sessionID: "sess-demo-1",
                sessionHandle: AgentSessionHandle(engine: .lody, sessionID: "sess-demo-1", workspacePath: "/Users/dev/code/web", launchMode: .nativeBackgroundSession),
                executionOutput: .structuredReply(StructuredReplyResult(
                    summary: isZH
                        ? "Gemini 4 Neon 正在后台审查中 · 已用上下文 156.0K"
                        : "Gemini 4 Neon reviewing in background · Context 156.0K",
                    replyMarkdown: ""
                )),
                remoteSessionStatus: .running
            )
        ]
        render(
            view: MenuBarContentView(coordinator: s3),
            scheme: .dark,
            height: 486,
            language: language,
            to: dir.appendingPathComponent("showcase-03-running-lody-failed-dark.png")
        )

        // 4. 草稿与已派发全状态：草稿就绪（含严重/建议/细节）+ Lody 审查完成 + 已提 Request Changes「待修复」（亮色）
        let s4 = makeBaseCoord()
        s4.items = [
            CollaborationItem(
                id: "sc-draft-cli",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/sync-engine",
                externalRef: "#305",
                title: "perf(queue): batch webhook flush with backpressure cap",
                url: URL(string: "https://github.com/acme/sync-engine/pull/305")!,
                author: "charlie",
                triggeredBy: "charlie",
                triggerKind: .mention,
                payload: .codeChange(CodeChangePayload(repository: "acme/sync-engine", number: 305, baseRef: "main", headRef: "perf/batch", headSHA: "c0ffee1", additions: 148, deletions: 39, changedFiles: 5)),
                status: .draftReady,
                sessionID: "claude_sess_9",
                sessionHandle: AgentSessionHandle(engine: .claudeCode, sessionID: "claude_sess_9", workspacePath: "/tmp/wt", launchMode: .managedStructuredRun),
                localReportPath: "/tmp/report.md",
                executionOutput: .codeReview(CodeReviewResult(
                    summary: isZH
                        ? "批处理主链路清晰，发现 1 处并发取消未释放信号量的边界问题及 2 处建议优化。"
                        : "Batch flushing path is clean; found 1 critical semaphore leak on cancellation and 2 suggested improvements.",
                    recommendedVerdict: .requestChanges,
                    comments: [
                        CodeInlineComment(path: "Sources/BatchFlusher.swift", line: 88, severity: .critical, title: isZH ? "取消分支未释放许可" : "Permit not released on cancel", body: isZH ? "建议移入 defer" : "Move release into defer"),
                        CodeInlineComment(path: "Sources/BatchFlusher.swift", line: 112, severity: .warning, title: isZH ? "缺少最大批大小兜底" : "Missing max batch cap", body: isZH ? "建议限制 500" : "Cap at 500"),
                        CodeInlineComment(path: "Sources/BatchFlusher.swift", line: 140, severity: .nit, title: isZH ? "日志字段命名统一" : "Consistent log field name", body: isZH ? "改为 batchSize" : "Rename to batchSize")
                    ]
                ))
            ),
            CollaborationItem(
                id: "sc-lody-done",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/cli",
                externalRef: "#1",
                title: "fix(cli): compare an unrecorded base against the remote default branch",
                url: URL(string: "https://github.com/acme/cli/pull/1")!,
                author: "alex-dev",
                triggeredBy: "alex-dev",
                triggerKind: .reviewRequested,
                payload: .codeChange(CodeChangePayload(repository: "acme/cli", number: 1, baseRef: "main", headRef: "fix/base", headSHA: "1234", additions: 88, deletions: 12, changedFiles: 4)),
                status: .draftReady,
                sessionID: "sess-demo-2",
                sessionHandle: AgentSessionHandle(engine: .lody, sessionID: "sess-demo-2", workspacePath: "/Users/dev/code/cli", launchMode: .nativeBackgroundSession),
                executionOutput: .structuredReply(StructuredReplyResult(
                    summary: isZH
                        ? "Gemini 4 Neon 已完成审查 · 耗时 4m 35s · 上下文 84.9K"
                        : "Gemini 4 Neon finished review · Duration 4m 35s · Context 84.9K",
                    replyMarkdown: ""
                )),
                remoteSessionStatus: .completed
            ),
            CollaborationItem(
                id: "sc-lody-changes-req",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/web",
                externalRef: "#4800",
                title: "fix(trust-safety): page chat moderation by cursor and drop the config hint",
                url: URL(string: "https://github.com/acme/web/pull/4800")!,
                author: "carol",
                triggeredBy: "carol",
                triggerKind: .reviewRequested,
                payload: .codeChange(CodeChangePayload(repository: "acme/web", number: 4800, baseRef: "develop", headRef: "fix/chat-moderation-followups", headSHA: "0762c65", additions: 534, deletions: 204, changedFiles: 28)),
                status: .draftReady,
                sessionID: "sess-demo-1",
                sessionHandle: AgentSessionHandle(engine: .lody, sessionID: "sess-demo-1", workspacePath: "/Users/dev/code/web", launchMode: .nativeBackgroundSession),
                executionOutput: .structuredReply(StructuredReplyResult(
                    summary: isZH
                        ? "Gemini 4 Neon 已完成审查 · 耗时 3m 12s · 上下文 188.6K"
                        : "Gemini 4 Neon finished review · Duration 3m 12s · Context 188.6K",
                    replyMarkdown: ""
                )),
                remoteSessionStatus: .completed,
                gitHubReviewVerdict: "CHANGES_REQUESTED"
            )
        ]
        render(
            view: MenuBarContentView(coordinator: s4),
            scheme: .light,
            height: 540,
            language: language,
            to: dir.appendingPathComponent("showcase-04-drafts-and-waitfix-light.png")
        )

        // 5. 展开「+ 导入 PR 链接」与暂停状态（暗色）
        let s5 = makeBaseCoord()
        s5.items.removeAll { $0.status != .pendingConfirmation }
        s5.isPaused = true
        render(
            view: MenuBarContentView(coordinator: s5, initialShowImportBar: true),
            scheme: .dark,
            height: 416,
            language: language,
            to: dir.appendingPathComponent("showcase-05-import-bar-paused-dark.png")
        )

        // 6. 「已完成」归档页全类型（已 Approve / 已合并 / 已关闭 / 手动完成 / 已忽略）
        let s6 = makeBaseCoord()
        s6.items = [
            CollaborationItem(
                id: "sc-done-superseded",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/backend",
                externalRef: "#482",
                title: "feat: cursor pagination with keyset index",
                url: URL(string: "https://github.com/acme/backend/pull/482")!,
                author: "carol",
                triggeredBy: "carol",
                triggerKind: .reviewRequested,
                payload: .codeChange(CodeChangePayload(repository: "acme/backend", number: 482, baseRef: "develop", headRef: "feat/pagination", headSHA: "a0", additions: 88, deletions: 14, changedFiles: 4)),
                status: .completed,
                reviewRound: 1,
                completionReason: .superseded
            ),
            CollaborationItem(
                id: "sc-done-approved",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/web",
                externalRef: "#4790",
                title: "perf(record): optimize text date formatting and wide-row copies",
                url: URL(string: "https://github.com/acme/web/pull/4790")!,
                author: "alice",
                triggeredBy: "alice",
                triggerKind: .reviewRequested,
                payload: .codeChange(CodeChangePayload(repository: "acme/web", number: 4790, baseRef: "develop", headRef: "perf/date", headSHA: "a1", additions: 40, deletions: 12, changedFiles: 3)),
                status: .completed,
                completionReason: .prApproved
            ),
            CollaborationItem(
                id: "sc-done-merged",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/web",
                externalRef: "#4778",
                title: "fix(oauth): make revoke endpoint idempotent under retry",
                url: URL(string: "https://github.com/acme/web/pull/4778")!,
                author: "bob",
                triggeredBy: "bob",
                triggerKind: .reviewRequested,
                payload: .codeChange(CodeChangePayload(repository: "acme/web", number: 4778, baseRef: "develop", headRef: "fix/oauth", headSHA: "a2", additions: 22, deletions: 6, changedFiles: 2)),
                status: .completed,
                completionReason: .prMerged
            ),
            CollaborationItem(
                id: "sc-done-closed",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/infra",
                externalRef: "#988",
                title: "chore(ci): experimental cache shard split",
                url: URL(string: "https://github.com/acme/infra/pull/988")!,
                author: "charlie",
                triggeredBy: "charlie",
                triggerKind: .mention,
                payload: .codeChange(CodeChangePayload(repository: "acme/infra", number: 988, baseRef: "main", headRef: "chore/ci", headSHA: "a3", additions: 15, deletions: 15, changedFiles: 1)),
                status: .completed,
                completionReason: .prClosed
            ),
            CollaborationItem(
                id: "sc-done-manual",
                platform: .feishu,
                itemKind: .conversation,
                scope: isZH ? "#支付值班群" : "#payments-oncall",
                externalRef: isZH ? "话题" : "Thread",
                title: isZH ? "线上回调偶发 504，疑似重试队列堆积" : "Intermittent 504 on production callbacks, suspected retry queue backlog",
                url: URL(string: "https://open.feishu.cn/")!,
                author: "diana",
                triggeredBy: "diana",
                triggerKind: .mention,
                payload: .conversation(ConversationPayload(channelName: isZH ? "#支付值班群" : "#payments-oncall", threadID: "om_1", recentSnippets: [], linkedRepository: "acme/backend")),
                status: .completed,
                completionReason: .manual
            ),
            CollaborationItem(
                id: "sc-done-dismissed",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/docs",
                externalRef: "#88",
                title: "docs: fix typo in changelog",
                url: URL(string: "https://github.com/acme/docs/pull/88")!,
                author: "evan",
                triggeredBy: "evan",
                triggerKind: .mention,
                payload: .codeChange(CodeChangePayload(repository: "acme/docs", number: 88, baseRef: "main", headRef: "docs/typo", headSHA: "a4", additions: 1, deletions: 1, changedFiles: 1)),
                status: .dismissed
            )
        ]
        s6.selectedTab = .completed
        render(
            view: MenuBarContentView(coordinator: s6),
            scheme: .light,
            height: 390,
            language: language,
            to: dir.appendingPathComponent("showcase-06-completed-all-reasons-light.png")
        )

        // 7. 点进 PR 的确认卡片（Codex：模型 / 强度 / 模式 / 模板 / 目录）
        let s7 = makeBaseCoord()
        render(
            view: MenuBarContentView(coordinator: s7, initialDetailItemID: "demo-gh-482"),
            scheme: .dark,
            height: CDTheme.detailHeight,
            language: language,
            to: dir.appendingPathComponent("showcase-07-detail-confirm-dark.png")
        )

        // 8. 点进「第 2 轮复审」确认卡片（上一轮由 Codex 审查，本轮聚焦增量 Diff）
        let s8 = makeBaseCoord()
        if let idx = s8.items.firstIndex(where: { $0.id == "demo-gh-482" }) {
            s8.items[idx].previousReview = PreviousReviewContext(
                previousItemID: "demo-gh-482-r1",
                reviewedHeadSHA: "99aabb1",
                reviewedAt: Date().addingTimeInterval(-3600),
                engine: .codex,
                model: "gpt-5.3-codex",
                sessionID: "0199c3a2-7b1e-7f30-9a4d-5e2f8c61d0b7",
                summarySnippet: isZH ? "发现 1 处并发刷新竞态" : "Found 1 concurrent refresh race condition",
                reviewRound: 1
            )
            s8.items[idx].reviewRound = 2
        }
        render(
            view: MenuBarContentView(coordinator: s8, initialDetailItemID: "demo-gh-482"),
            scheme: .dark,
            height: CDTheme.detailHeight,
            language: language,
            to: dir.appendingPathComponent("showcase-08-detail-rereview-dark.png")
        )
    }

    private static func renderMenuBarIconsSheet(to url: URL, language: ResolvedLanguage) {
        let isZH = (language == .zhHans)
        let states: [(label: String, isPaused: Bool, running: Int, pending: Int, draft: Int, err: Bool, blink: Bool, iconState: PeekCatMenuBarState)] = [
            (isZH ? "空闲" : "Idle", false, 0, 0, 0, false, false, .idle),
            (isZH ? "待确认 3" : "Pending 3", false, 0, 3, 0, false, false, .pending),
            (isZH ? "执行中 1" : "Running 1", false, 1, 0, 0, false, false, .running(blinking: false)),
            (isZH ? "执行眨眼" : "Blinking", false, 1, 0, 0, false, true, .running(blinking: true)),
            (isZH ? "草稿就绪" : "Draft Ready", false, 0, 0, 1, false, false, .draftReady),
            (isZH ? "已暂停" : "Paused", true, 0, 0, 0, false, false, .paused),
            (isZH ? "异常" : "Error", false, 0, 0, 0, true, false, .error)
        ]

        let sheet = VStack(alignment: .leading, spacing: 18) {
            Text(isZH ? "CollabDock · 猫坞 PeekCat 歪头招手猫 菜单栏实渲染验真" : "CollabDock · PeekCat Menu Bar Icon States")
                .font(.system(size: 14, weight: .semibold))

            // 1. 浅色 macOS 菜单栏 1:1 实测
            VStack(alignment: .leading, spacing: 6) {
                Text(isZH ? "浅色菜单栏（18×18pt 真实尺寸）" : "Light Menu Bar (18×18pt actual size)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    ForEach(states, id: \.label) { s in
                        VStack(spacing: 5) {
                            MenuBarStatusLabel(
                                isPaused: s.isPaused,
                                runningCount: s.running,
                                pendingCount: s.pending,
                                draftReadyCount: s.draft,
                                hasSyncError: s.err,
                                isBlinking: s.blink
                            )
                            .foregroundStyle(Color(white: 0.1))
                            Text(s.label)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // 2. 深色 macOS 菜单栏 1:1 实测
            VStack(alignment: .leading, spacing: 6) {
                Text(isZH ? "深色菜单栏（18×18pt 真实尺寸）" : "Dark Menu Bar (18×18pt actual size)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    ForEach(states, id: \.label) { s in
                        VStack(spacing: 5) {
                            MenuBarStatusLabel(
                                isPaused: s.isPaused,
                                runningCount: s.running,
                                pendingCount: s.pending,
                                draftReadyCount: s.draft,
                                hasSyncError: s.err,
                                isBlinking: s.blink
                            )
                            .foregroundStyle(Color(white: 0.95))
                            Text(s.label)
                                .font(.system(size: 10))
                                .foregroundStyle(Color(white: 0.68))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(red: 0.11, green: 0.12, blue: 0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // 3. 3x 放大细节验真（54×54pt）
            VStack(alignment: .leading, spacing: 6) {
                Text(isZH ? "3× 放大细节验真（检查歪头角度、招手爪、镂空眼睛与角标）" : "3× Zoomed Detail (54×54pt)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    ForEach(states, id: \.label) { s in
                        VStack(spacing: 6) {
                            Image(nsImage: PeekCatMenuBarRenderer.renderImage(
                                state: s.iconState,
                                pointSize: 54,
                                pixelScale: 2,
                                asTemplate: false,
                                tintColor: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.15, alpha: 1)
                            ))
                            Text(s.label)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 68)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
        .padding(20)

        renderWindow(view: sheet, scheme: .light, width: 620, height: 350, language: language, to: url)
    }

    private static func renderWindow<V: View>(
        view: V,
        scheme: ColorScheme,
        width: CGFloat,
        height: CGFloat,
        language: ResolvedLanguage,
        to url: URL
    ) {
        let size = NSSize(width: width, height: height)
        let wrapped = view
            .frame(width: width, height: height)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: language.lprojCode))
        let hosting = NSHostingView(rootView: wrapped)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return }
        try? pngData.write(to: url)
    }

    private static func render<V: View>(
        view: V,
        scheme: ColorScheme,
        height: CGFloat,
        language: ResolvedLanguage,
        to url: URL
    ) {
        let backdrop = scheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.125)
            : Color(red: 0.945, green: 0.945, blue: 0.96)

        let wrapped = view
            .frame(width: CDTheme.popoverWidth, height: height)
            .background(backdrop)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 0.75)
            )
            .padding(16)
            .background(scheme == .dark ? Color(white: 0.06) : Color(white: 0.86))
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: language.lprojCode))

        let size = NSSize(width: CDTheme.popoverWidth + 32, height: height + 32)
        let hosting = NSHostingView(rootView: wrapped)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return }
        try? pngData.write(to: url)
    }
}
#endif
