import Foundation

/// 跨平台统一触发规则（可全局配置，也可按连接器单独覆写，关联 REQ-003, ADR-005）
public struct TriggerRules: Codable, Hashable, Sendable {
    public var enableMention: Bool
    public var enableReviewRequested: Bool
    public var enableAssigned: Bool
    public var enableTeamMention: Bool
    public var requireMentionKeywords: Bool
    public var mentionKeywords: [String]
    /// 作用域白名单（GitHub/GitLab 仓库 `org/*`、飞书/Slack 频道 `#oncall*`、Linear Team 等；空表示全部）
    public var scopeAllowlist: [String]
    /// 作用域黑名单（优先级高于白名单）
    public var scopeDenylist: [String]
    public var ignoreDraftItems: Bool
    public var ignoreBots: Bool
    public var parseTriggerHints: Bool

    public init(
        enableMention: Bool = true,
        enableReviewRequested: Bool = true,
        enableAssigned: Bool = true,
        enableTeamMention: Bool = false,
        requireMentionKeywords: Bool = true,
        mentionKeywords: [String] = ["review", "cr", "帮忙看", "请看", "排查", "check"],
        scopeAllowlist: [String] = [],
        scopeDenylist: [String] = [],
        ignoreDraftItems: Bool = true,
        ignoreBots: Bool = true,
        parseTriggerHints: Bool = true
    ) {
        self.enableMention = enableMention
        self.enableReviewRequested = enableReviewRequested
        self.enableAssigned = enableAssigned
        self.enableTeamMention = enableTeamMention
        self.requireMentionKeywords = requireMentionKeywords
        self.mentionKeywords = mentionKeywords
        self.scopeAllowlist = scopeAllowlist
        self.scopeDenylist = scopeDenylist
        self.ignoreDraftItems = ignoreDraftItems
        self.ignoreBots = ignoreBots
        self.parseTriggerHints = parseTriggerHints
    }
}

/// 单个协作连接器的开关与身份配置
public struct ConnectorConfig: Codable, Hashable, Sendable, Identifiable {
    public let platform: PlatformKind
    public var isEnabled: Bool
    /// 当前用户在该平台的标识名（用于 @mention 匹配和防自循环）
    public var accountHandle: String
    /// 可选：该平台专属的触发规则覆写；nil 表示沿用全局默认规则
    public var customRules: TriggerRules?

    public var id: PlatformKind { platform }

    public init(
        platform: PlatformKind,
        isEnabled: Bool,
        accountHandle: String = "",
        customRules: TriggerRules? = nil
    ) {
        self.platform = platform
        self.isEnabled = isEnabled
        self.accountHandle = accountHandle
        self.customRules = customRules
    }

    public static let defaults: [ConnectorConfig] = [
        ConnectorConfig(platform: .github, isEnabled: true),
        ConnectorConfig(platform: .gitlab, isEnabled: false),
        ConnectorConfig(platform: .feishu, isEnabled: false),
        ConnectorConfig(platform: .slack, isEnabled: false),
        ConnectorConfig(platform: .linear, isEnabled: false)
    ]
}

public enum PromptTemplateKind: String, CaseIterable, Hashable, Sendable {
    case firstReview
    case followUp
}

public enum TaskPresetCategory: String, Codable, Hashable, Sendable {
    case codeReview
    case troubleshooting
    case generalCollaboration
}

public struct TaskPreset: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var category: TaskPresetCategory
    public var promptInstructions: String
    public var followUpPromptInstructions: String

    public init(
        id: String,
        name: String,
        category: TaskPresetCategory,
        promptInstructions: String = "",
        followUpPromptInstructions: String = ""
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.promptInstructions = promptInstructions
        self.followUpPromptInstructions = followUpPromptInstructions
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, promptInstructions, followUpPromptInstructions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.category = try c.decode(TaskPresetCategory.self, forKey: .category)
        self.promptInstructions = (try? c.decodeIfPresent(String.self, forKey: .promptInstructions)) ?? ""
        self.followUpPromptInstructions = (try? c.decodeIfPresent(String.self, forKey: .followUpPromptInstructions)) ?? ""
    }

    /// 旧版（ITER-011 ~ PR #15）默认提示词文案；加载旧配置时若正好等于此句，自动迁移为空字符串以跟随当前界面语言内置默认模板
    public static let legacyDefaultPromptInstructions = "请帮我 review 这个 PR。"

    /// 当前界面语言的内置默认模板（模板字段留空或仅含空白时使用）
    public static func defaultTemplate(for kind: PromptTemplateKind, language: ResolvedLanguage) -> String {
        switch (kind, language) {
        case (.firstReview, .zhHans):
            return "请帮我 review 这个 PR：{{pr_url}}"
        case (.followUp, .zhHans):
            return "PR 已经更新，请继续审查：{{pr_url}}"
        case (.firstReview, .en):
            return "Please review this PR: {{pr_url}}"
        case (.followUp, .en):
            return "The PR has been updated. Please continue reviewing: {{pr_url}}"
        }
    }

    /// 返回生效模板：自定义非空白时返回自定义内容，否则回退当前界面语言的内置默认模板
    public func effectiveTemplate(for kind: PromptTemplateKind, language: ResolvedLanguage) -> String {
        let raw: String = switch kind {
        case .firstReview:
            promptInstructions
        case .followUp:
            followUpPromptInstructions
        }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self.defaultTemplate(for: kind, language: language)
        }
        return raw
    }

    /// 极简默认预制：两个模板字段均留空，从而始终跟随当前界面语言的内置默认模板
    public static let defaults: [TaskPreset] = [
        TaskPreset(
            id: "code-review-general",
            name: "Review 这个 PR",
            category: .codeReview
        )
    ]

    /// 旧版（ITER-000 ~ ITER-010）6 条出厂预制清单，用于无损识别未修改过模板的旧配置并平滑精简
    public static let legacyFactoryDefaults: [TaskPreset] = [
        TaskPreset(
            id: "code-review-general",
            name: "通用代码审查",
            category: .codeReview,
            promptInstructions: "重点关注逻辑缺陷、边界条件、并发竞争、错误处理、类型安全与可维护性；仅输出高信噪比意见，避免无意义的格式挑刺。"
        ),
        TaskPreset(
            id: "code-review-security",
            name: "安全与鉴权审计",
            category: .codeReview,
            promptInstructions: "重点审计注入漏洞、鉴权/权限绕过、敏感信息泄露、输入校验缺失、路径遍历与不安全默认配置。"
        ),
        TaskPreset(
            id: "code-review-architecture",
            name: "架构与性能审查",
            category: .codeReview,
            promptInstructions: "重点评估模块边界、API 兼容性、数据库查询/N+1 性能风险、内存泄漏与可扩展性。"
        ),
        TaskPreset(
            id: "code-review-bugs",
            name: "仅查确定性 Bug",
            category: .codeReview,
            promptInstructions: "只报告明确会导致线上故障、数据损坏、崩溃或安全漏洞的严重问题，不输出风格建议。"
        ),
        TaskPreset(
            id: "triage-root-cause",
            name: "问题定位与根因分析",
            category: .troubleshooting,
            promptInstructions: "结合关联本地代码库只读检索调用链，定位根因、列出涉及的文件与行号，并给出清晰可执行的修复方案草稿。"
        ),
        TaskPreset(
            id: "collab-quick-answer",
            name: "协作答疑与方案评审",
            category: .generalCollaboration,
            promptInstructions: "基于事实与本地代码依据，给出简洁、准确、结构化的回复草稿，明确标注不确定假设。"
        )
    ]
}

/// 团队共享配置包（导入时不覆盖个人偏好，关联 REQ-011）
public struct TeamPreset: Codable, Hashable, Sendable {
    public var teamName: String
    public var scopeAllowlist: [String]
    public var mentionKeywords: [String]
    public var taskPresets: [TaskPreset]

    public init(
        teamName: String,
        scopeAllowlist: [String],
        mentionKeywords: [String],
        taskPresets: [TaskPreset]
    ) {
        self.teamName = teamName
        self.scopeAllowlist = scopeAllowlist
        self.mentionKeywords = mentionKeywords
        self.taskPresets = taskPresets
    }
}

/// Lody.ai 工作区与会话派发配置（关联 REQ-014, ADR-007, ITER-009）
public struct LodyConfig: Codable, Hashable, Sendable {
    /// 目标 Lody Workspace 名称或 ID（留空使用当前默认 Workspace）
    public var workspace: String
    /// 默认 Lody agent-config 的 ID 或名称（如真实 UUID / "Antigravity" / "Claude Code"；"default" 表示省略参数）
    public var defaultAgentConfig: String
    /// 按每个 Lody agent-config 记忆各自偏好的默认模型 ID（如 `antigravity -> gemini-4-neon`）
    public var defaultModelByAgentConfig: [String: String]
    /// 按每个 Lody agent-config 记忆各自偏好的默认执行模式 ID（如 `plan` / `default` / `auto` / `read-only`，关联 ITER-016）
    public var defaultModeByAgentConfig: [String: String]
    /// 当 PATH 未全局安装 `lody` 时，自动通过 `npx -y lody` 调用
    public var preferNPXFallback: Bool
    /// 对关联 GitHub 仓库的任务，优先传 `--repo` 交由 Lody 原生隔离 Worktree 管理
    public var useLodyWorktree: Bool

    public init(
        workspace: String = "",
        defaultAgentConfig: String = "default",
        defaultModelByAgentConfig: [String: String] = [:],
        defaultModeByAgentConfig: [String: String] = [:],
        preferNPXFallback: Bool = true,
        useLodyWorktree: Bool = true
    ) {
        self.workspace = workspace
        self.defaultAgentConfig = defaultAgentConfig
        self.defaultModelByAgentConfig = defaultModelByAgentConfig
        self.defaultModeByAgentConfig = defaultModeByAgentConfig
        self.preferNPXFallback = preferNPXFallback
        self.useLodyWorktree = useLodyWorktree
    }

    enum CodingKeys: String, CodingKey {
        case workspace, defaultAgentConfig, defaultModelByAgentConfig, defaultModeByAgentConfig, preferNPXFallback, useLodyWorktree
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = LodyConfig()
        self.workspace = (try? c.decodeIfPresent(String.self, forKey: .workspace)) ?? fallback.workspace
        self.defaultAgentConfig = (try? c.decodeIfPresent(String.self, forKey: .defaultAgentConfig)) ?? fallback.defaultAgentConfig
        self.defaultModelByAgentConfig = (try? c.decodeIfPresent([String: String].self, forKey: .defaultModelByAgentConfig)) ?? fallback.defaultModelByAgentConfig
        self.defaultModeByAgentConfig = (try? c.decodeIfPresent([String: String].self, forKey: .defaultModeByAgentConfig)) ?? fallback.defaultModeByAgentConfig
        self.preferNPXFallback = (try? c.decodeIfPresent(Bool.self, forKey: .preferNPXFallback)) ?? fallback.preferNPXFallback
        self.useLodyWorktree = (try? c.decodeIfPresent(Bool.self, forKey: .useLodyWorktree)) ?? fallback.useLodyWorktree
    }
}

/// 可选的「收到请求自动开始审查」配置（默认关闭，关联 PR #21）
public struct AutoStartSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var triggerKinds: [TriggerKind]
    /// 仓库白名单（空表示所有通过触发规则的仓库；支持 `owner/*` / `owner/prefix*` 通配）
    public var repositoryAllowlist: [String]
    public var continueReReviews: Bool
    public var notifyOnStart: Bool
    public var isPaused: Bool

    public init(
        isEnabled: Bool = false,
        triggerKinds: [TriggerKind] = [.reviewRequested],
        repositoryAllowlist: [String] = [],
        continueReReviews: Bool = true,
        notifyOnStart: Bool = true,
        isPaused: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.triggerKinds = triggerKinds
        self.repositoryAllowlist = repositoryAllowlist
        self.continueReReviews = continueReReviews
        self.notifyOnStart = notifyOnStart
        self.isPaused = isPaused
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, triggerKinds, repositoryAllowlist, continueReReviews, notifyOnStart, isPaused
    }

    /// 逐字段容错解码：单个字段损坏（如来自未来版本的未知 TriggerKind）只回落该字段默认值，其余字段保留
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AutoStartSettings()
        self.isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? fallback.isEnabled
        self.triggerKinds = (try? c.decodeIfPresent([TriggerKind].self, forKey: .triggerKinds)) ?? fallback.triggerKinds
        self.repositoryAllowlist = (try? c.decodeIfPresent([String].self, forKey: .repositoryAllowlist)) ?? fallback.repositoryAllowlist
        self.continueReReviews = (try? c.decodeIfPresent(Bool.self, forKey: .continueReReviews)) ?? fallback.continueReReviews
        self.notifyOnStart = (try? c.decodeIfPresent(Bool.self, forKey: .notifyOnStart)) ?? fallback.notifyOnStart
        self.isPaused = (try? c.decodeIfPresent(Bool.self, forKey: .isPaused)) ?? fallback.isPaused
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var pollIntervalSeconds: Int
    public var launchAtLogin: Bool
    public var notificationsEnabled: Bool
    public var connectors: [ConnectorConfig]
    public var globalTriggerRules: TriggerRules
    public var defaultEngine: AgentEngine
    public var defaultEffort: ReasoningEffort
    public var lodyConfig: LodyConfig
    public var customExecutablePaths: [String: String]
    public var workspaceSearchRoots: [String]
    /// 手动指定的 `owner/repo`（小写）-> 本地目录路径映射，优先级高于自动扫描与 Lody 本地项目默认顺序（关联 ITER-012）
    public var repositoryDirectoryOverrides: [String: String]
    /// 用量统计参考费用显示币种（USD / CNY，可在设置中随时切换，关联 ITER-014）
    public var usageCurrency: UsageCurrency
    /// 开发者模式（隐藏触发解锁：用于加载/清理测试与示例数据，默认关闭，关联 ITER-015）
    public var developerModeEnabled: Bool
    /// 当收件箱中的 PR 在 GitHub 被你 Approve、或已合并/关闭时自动归档至「已完成」（Request Changes 保留跟进，关联 ITER-017）
    public var autoCompleteApprovedOrClosedPRs: Bool
    /// 收到请求后自动开始审查的配置（默认关闭，关联 PR #21）
    public var autoStart: AutoStartSettings
    /// 开始审查（Lody 会话派发成功）时在 PR / 触发评论上添加 👀 表情（默认开启，关联 ADR-009）
    public var markReviewStartWithReaction: Bool
    /// 界面语言（跟随系统 / 简体中文 / English，重启后生效，关联 issue #4）
    public var appLanguage: AppLanguage
    public var presets: [TaskPreset]

    public init(
        pollIntervalSeconds: Int = 60,
        launchAtLogin: Bool = false,
        notificationsEnabled: Bool = true,
        connectors: [ConnectorConfig] = ConnectorConfig.defaults,
        globalTriggerRules: TriggerRules = TriggerRules(),
        defaultEngine: AgentEngine = .lody,
        defaultEffort: ReasoningEffort = .high,
        lodyConfig: LodyConfig = LodyConfig(),
        customExecutablePaths: [String: String] = [:],
        workspaceSearchRoots: [String] = ["~/work", "~/projects"],
        repositoryDirectoryOverrides: [String: String] = [:],
        usageCurrency: UsageCurrency = .usd,
        developerModeEnabled: Bool = false,
        autoCompleteApprovedOrClosedPRs: Bool = true,
        autoStart: AutoStartSettings = AutoStartSettings(),
        markReviewStartWithReaction: Bool = true,
        appLanguage: AppLanguage = .system,
        presets: [TaskPreset] = TaskPreset.defaults
    ) {
        self.pollIntervalSeconds = max(60, pollIntervalSeconds)
        self.launchAtLogin = launchAtLogin
        self.notificationsEnabled = notificationsEnabled
        self.connectors = connectors
        self.globalTriggerRules = globalTriggerRules
        self.defaultEngine = .lody
        self.defaultEffort = defaultEffort
        self.lodyConfig = lodyConfig
        self.customExecutablePaths = customExecutablePaths
        self.workspaceSearchRoots = workspaceSearchRoots
        self.repositoryDirectoryOverrides = repositoryDirectoryOverrides
        self.usageCurrency = usageCurrency
        self.developerModeEnabled = developerModeEnabled
        self.autoCompleteApprovedOrClosedPRs = autoCompleteApprovedOrClosedPRs
        self.autoStart = autoStart
        self.markReviewStartWithReaction = markReviewStartWithReaction
        self.appLanguage = appLanguage
        self.presets = presets
    }

    enum CodingKeys: String, CodingKey {
        case pollIntervalSeconds, launchAtLogin, notificationsEnabled, connectors
        case globalTriggerRules, defaultEngine, defaultEffort
        case lodyConfig
        case customExecutablePaths, workspaceSearchRoots, repositoryDirectoryOverrides
        case usageCurrency, developerModeEnabled, autoCompleteApprovedOrClosedPRs
        case autoStart, markReviewStartWithReaction
        case appLanguage, presets
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case defaultModels
    }

    /// 向后兼容解码：旧直连引擎键、reviewLanguage 与 injectPresetPrompt 静默忽略，legacy defaultEngine 归一为 .lody
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let fallback = AppSettings()
        self.pollIntervalSeconds = max(60, (try? c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds)) ?? fallback.pollIntervalSeconds)
        self.launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? fallback.launchAtLogin
        self.notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? fallback.notificationsEnabled
        self.connectors = (try? c.decodeIfPresent([ConnectorConfig].self, forKey: .connectors)) ?? fallback.connectors
        self.globalTriggerRules = (try? c.decodeIfPresent(TriggerRules.self, forKey: .globalTriggerRules)) ?? fallback.globalTriggerRules
        self.defaultEngine = .lody

        var decodedLody = (try? c.decodeIfPresent(LodyConfig.self, forKey: .lodyConfig)) ?? fallback.lodyConfig
        // 平滑迁移旧版把 Lody Agent Config 存在 defaultModels["lody"] 的配置
        let legacyLodyModel: String? = {
            if let nativeDict = try? legacy.decodeIfPresent([AgentEngine: String].self, forKey: .defaultModels) {
                return nativeDict[.lody]
            }
            if let stringDict = try? legacy.decodeIfPresent([String: String].self, forKey: .defaultModels) {
                return stringDict["lody"]
            }
            return nil
        }()
        let legacyAgentPlaceholders: Set<String> = ["claude", "codex", "antigravity"]
        if let legacyLodyVal = legacyLodyModel?.lowercased(), legacyAgentPlaceholders.contains(legacyLodyVal) {
            if decodedLody.defaultAgentConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || decodedLody.defaultAgentConfig == "default" {
                decodedLody.defaultAgentConfig = legacyLodyVal
            }
        }

        self.defaultEffort = (try? c.decodeIfPresent(ReasoningEffort.self, forKey: .defaultEffort)) ?? fallback.defaultEffort
        self.lodyConfig = decodedLody
        self.customExecutablePaths = (try? c.decodeIfPresent([String: String].self, forKey: .customExecutablePaths)) ?? fallback.customExecutablePaths
        self.workspaceSearchRoots = (try? c.decodeIfPresent([String].self, forKey: .workspaceSearchRoots)) ?? fallback.workspaceSearchRoots
        self.repositoryDirectoryOverrides = (try? c.decodeIfPresent([String: String].self, forKey: .repositoryDirectoryOverrides)) ?? fallback.repositoryDirectoryOverrides
        self.usageCurrency = (try? c.decodeIfPresent(UsageCurrency.self, forKey: .usageCurrency)) ?? fallback.usageCurrency
        self.developerModeEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .developerModeEnabled)) ?? fallback.developerModeEnabled
        self.autoCompleteApprovedOrClosedPRs = (try? c.decodeIfPresent(Bool.self, forKey: .autoCompleteApprovedOrClosedPRs)) ?? fallback.autoCompleteApprovedOrClosedPRs
        self.autoStart = (try? c.decodeIfPresent(AutoStartSettings.self, forKey: .autoStart)) ?? fallback.autoStart
        self.markReviewStartWithReaction = (try? c.decodeIfPresent(Bool.self, forKey: .markReviewStartWithReaction)) ?? fallback.markReviewStartWithReaction
        self.appLanguage = (try? c.decodeIfPresent(AppLanguage.self, forKey: .appLanguage)) ?? fallback.appLanguage
        var decodedPresets = (try? c.decodeIfPresent([TaskPreset].self, forKey: .presets)) ?? fallback.presets
        // 若用户从未改过旧版 6 条出厂预制，平滑精简为新版极简默认；若用户自定义过任何模板则 100% 保留
        if decodedPresets == TaskPreset.legacyFactoryDefaults {
            decodedPresets = TaskPreset.defaults
        } else {
            // 若预制里存的正好是旧版默认文案，迁移为空以自动跟随当前界面语言内置默认模板，保留 id 与 name
            decodedPresets = decodedPresets.map { preset in
                var migrated = preset
                if migrated.promptInstructions == TaskPreset.legacyDefaultPromptInstructions {
                    migrated.promptInstructions = ""
                }
                return migrated
            }
        }
        self.presets = decodedPresets.isEmpty ? TaskPreset.defaults : decodedPresets
    }

    public func effectiveRules(for platform: PlatformKind) -> TriggerRules {
        connectors.first(where: { $0.platform == platform })?.customRules ?? globalTriggerRules
    }

    public mutating func applyTeamPreset(_ preset: TeamPreset) {
        if !preset.scopeAllowlist.isEmpty {
            globalTriggerRules.scopeAllowlist = preset.scopeAllowlist
        }
        if !preset.mentionKeywords.isEmpty {
            globalTriggerRules.mentionKeywords = preset.mentionKeywords
        }
        for incoming in preset.taskPresets {
            if let idx = presets.firstIndex(where: { $0.id == incoming.id }) {
                presets[idx] = incoming
            } else {
                presets.append(incoming)
            }
        }
    }
}
