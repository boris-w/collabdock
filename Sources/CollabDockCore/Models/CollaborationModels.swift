import Foundation

// MARK: - 协作平台与可插拔连接器标识（关联 ADR-005）

public enum PlatformKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case github
    case gitlab
    case feishu
    case slack
    case linear
    case jira
    case customWebhook

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        case .feishu: return "飞书"
        case .slack: return "Slack"
        case .linear: return "Linear"
        case .jira: return "Jira"
        case .customWebhook: return "Webhook"
        }
    }

    public var isFirstClassV1: Bool {
        self == .github
    }

    public var supportsCodeDiff: Bool {
        self == .github || self == .gitlab
    }

    public var supportsPlatformDraftReview: Bool {
        self == .github || self == .gitlab
    }
}

public enum CollaborationItemKind: String, Codable, Hashable, Sendable {
    case pullRequest
    case mergeRequest
    case issue
    case conversation
    case ticket

    public var shortLabel: String {
        switch self {
        case .pullRequest: return "PR"
        case .mergeRequest: return "MR"
        case .issue: return "Issue"
        case .conversation: return "群聊"
        case .ticket: return "工单"
        }
    }
}

public enum TriggerKind: String, Codable, Hashable, Sendable {
    case mention
    case reviewRequested
    case assigned
    case teamMention
    case threadReply

    public var badgeText: String {
        switch self {
        case .mention: return "@mention"
        case .reviewRequested: return "Request Review"
        case .assigned: return "Assigned"
        case .teamMention: return "Team Mention"
        case .threadReply: return "Thread Reply"
        }
    }
}

// MARK: - 强类型多平台扩展载荷

public struct CodeChangePayload: Codable, Hashable, Sendable {
    public let repository: String
    public let number: Int
    public let baseRef: String
    public let headRef: String
    public let headSHA: String
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    public let isDraft: Bool

    public init(
        repository: String,
        number: Int,
        baseRef: String,
        headRef: String,
        headSHA: String,
        additions: Int,
        deletions: Int,
        changedFiles: Int,
        isDraft: Bool = false
    ) {
        self.repository = repository
        self.number = number
        self.baseRef = baseRef
        self.headRef = headRef
        self.headSHA = headSHA
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.isDraft = isDraft
    }
}

public struct IssueTicketPayload: Codable, Hashable, Sendable {
    public let ticketKey: String
    public let labels: [String]
    public let priority: String?
    public let linkedRepository: String?

    public init(
        ticketKey: String,
        labels: [String] = [],
        priority: String? = nil,
        linkedRepository: String? = nil
    ) {
        self.ticketKey = ticketKey
        self.labels = labels
        self.priority = priority
        self.linkedRepository = linkedRepository
    }
}

public struct ConversationPayload: Codable, Hashable, Sendable {
    public let channelName: String
    public let threadID: String?
    public let recentSnippets: [String]
    public let linkedRepository: String?

    public init(
        channelName: String,
        threadID: String? = nil,
        recentSnippets: [String] = [],
        linkedRepository: String? = nil
    ) {
        self.channelName = channelName
        self.threadID = threadID
        self.recentSnippets = recentSnippets
        self.linkedRepository = linkedRepository
    }
}

public enum CollaborationPayload: Codable, Hashable, Sendable {
    case codeChange(CodeChangePayload)
    case issueTicket(IssueTicketPayload)
    case conversation(ConversationPayload)

    public var isDraftItem: Bool {
        switch self {
        case .codeChange(let payload): return payload.isDraft
        case .issueTicket, .conversation: return false
        }
    }

    public var linkedRepository: String? {
        switch self {
        case .codeChange(let payload): return payload.repository
        case .issueTicket(let payload): return payload.linkedRepository
        case .conversation(let payload): return payload.linkedRepository
        }
    }
}

// MARK: - AI 执行引擎与计划模型（关联 REQ-007, ADR-003）

/// 支持的本地 AI CLI 与会话编排引擎（关联 REQ-007, REQ-014, ADR-003, ADR-007）
public enum AgentEngine: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode = "claude"
    case codex = "codex"
    case antigravity = "agy"
    case lody = "lody"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .antigravity: return "Antigravity (agy)"
        case .lody: return "Lody (lody.ai)"
        }
    }

    public var defaultExecutableName: String { rawValue }

    public var defaultModels: [ModelOption] {
        switch self {
        case .claudeCode:
            return [
                ModelOption(id: "opus", displayName: "Claude Opus (Latest)"),
                ModelOption(id: "sonnet", displayName: "Claude Sonnet (Latest)"),
                ModelOption(id: "haiku", displayName: "Claude Haiku (Fast)")
            ]
        case .codex:
            return [
                ModelOption(id: "gpt-5.3-codex", displayName: "GPT-5.3 Codex"),
                ModelOption(id: "gpt-5-codex", displayName: "GPT-5 Codex"),
                ModelOption(id: "o3", displayName: "o3")
            ]
        case .antigravity:
            return [
                ModelOption(id: "gemini-4-neon-xhigh", displayName: "Gemini 4 Neon (XHigh)"),
                ModelOption(id: "gemini-4-neon-high", displayName: "Gemini 4 Neon (High)"),
                ModelOption(id: "gemini-4-carbon-high", displayName: "Gemini 4 Carbon (High)"),
                ModelOption(id: "claude-opus-5-5-high", displayName: "Claude Opus 5.5 (High)"),
                ModelOption(id: "gemini-3.8-flash-high", displayName: "Gemini 3.8 Flash (High)")
            ]
        case .lody:
            return [
                ModelOption(id: "default", displayName: "跟随 Agent 默认模型")
            ]
        }
    }

    /// 各引擎可选执行模式（Mode）：默认优先只读/规划，同时支持用户按需切到 Default / Accept edits / Auto / Agent 等模式（关联 ITER-016）
    public var defaultModes: [AgentModeOption] {
        switch self {
        case .claudeCode:
            return [
                AgentModeOption(id: "plan", displayName: "Plan（只读规划）"),
                AgentModeOption(id: "default", displayName: "Manual（修改前询问）"),
                AgentModeOption(id: "acceptEdits", displayName: "Accept edits（自动编辑）"),
                AgentModeOption(id: "auto", displayName: "Auto（自动决策）")
            ]
        case .antigravity:
            return [
                AgentModeOption(id: "plan", displayName: "Plan（只读规划）"),
                AgentModeOption(id: "default", displayName: "Default（默认询问）"),
                AgentModeOption(id: "accept-edits", displayName: "Accept edits（自动编辑）"),
                AgentModeOption(id: "auto", displayName: "Auto（自动执行）")
            ]
        case .codex:
            return [
                AgentModeOption(id: "read-only", displayName: "Read-only（只读沙箱）"),
                AgentModeOption(id: "workspace-write", displayName: "Workspace write（工作区可写）"),
                AgentModeOption(id: "danger-full-access", displayName: "Full access（完全权限）")
            ]
        case .lody:
            return [
                AgentModeOption(id: "__agent_default__", displayName: "跟随 Agent 默认模式")
            ]
        }
    }

    public var defaultSafeModeID: String {
        switch self {
        case .claudeCode, .antigravity: return "plan"
        case .codex: return "read-only"
        case .lody: return "__agent_default__"
        }
    }
}

public struct ModelOption: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct AgentModeOption: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let description: String?

    public init(id: String, displayName: String, description: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.description = description
    }
}

// MARK: - Lody.ai 实时目录模型（关联 REQ-014, ADR-007, ITER-009）

public struct LodyWorkspaceOption: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let slug: String?

    public init(id: String, name: String, slug: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
    }

    public var displayLabel: String {
        if let slug, !slug.isEmpty, slug != name {
            return "\(name) (\(slug))"
        }
        return name
    }
}

public struct LodyAgentConfigOption: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let agentType: String?
    public let models: [ModelOption]
    /// 该 Agent 支持的全部 ACP 执行模式（来自 `lody agent-config list --json` 的 `runConfig.modes`）
    public let modes: [AgentModeOption]
    /// Lody ACP `--config-option <key>=<value>` 对应的思考强度键（如 `thought_level` / `effort` / `reasoning_effort`）
    public let effortOptionKey: String?
    public let reasoningEffortValues: [String]
    /// 只读审查优先使用的 ACP mode（如 `read-only` 或 `plan`）
    public let readOnlyModeID: String?
    public let availabilityState: String?

    public init(
        id: String,
        name: String,
        agentType: String? = nil,
        models: [ModelOption] = [],
        modes: [AgentModeOption] = [],
        effortOptionKey: String? = nil,
        reasoningEffortValues: [String] = [],
        readOnlyModeID: String? = nil,
        availabilityState: String? = nil
    ) {
        self.id = id
        self.name = name
        self.agentType = agentType
        self.models = models
        self.modes = modes.isEmpty ? Self.fallbackModes(forAgentType: agentType ?? name) : modes
        self.effortOptionKey = effortOptionKey
        self.reasoningEffortValues = reasoningEffortValues
        self.readOnlyModeID = readOnlyModeID
        self.availabilityState = availabilityState
    }

    enum CodingKeys: String, CodingKey {
        case id, name, agentType, models, modes, effortOptionKey, reasoningEffortValues, readOnlyModeID, availabilityState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let name = try c.decode(String.self, forKey: .name)
        let agentType = try? c.decodeIfPresent(String.self, forKey: .agentType)
        let models = (try? c.decodeIfPresent([ModelOption].self, forKey: .models)) ?? []
        let rawModes = (try? c.decodeIfPresent([AgentModeOption].self, forKey: .modes)) ?? []
        self.id = id
        self.name = name
        self.agentType = agentType
        self.models = models
        self.modes = rawModes.isEmpty ? Self.fallbackModes(forAgentType: agentType ?? name) : rawModes
        self.effortOptionKey = try? c.decodeIfPresent(String.self, forKey: .effortOptionKey)
        self.reasoningEffortValues = (try? c.decodeIfPresent([String].self, forKey: .reasoningEffortValues)) ?? []
        self.readOnlyModeID = try? c.decodeIfPresent(String.self, forKey: .readOnlyModeID)
        self.availabilityState = try? c.decodeIfPresent(String.self, forKey: .availabilityState)
    }

    /// 离线或旧缓存未包含 modes 列表时，按 agentType 提供与真实 Lody CLI 对齐的模式列表
    public static func fallbackModes(forAgentType rawType: String) -> [AgentModeOption] {
        let token = rawType.lowercased()
        if token.contains("antigravity") || token.contains("agy") {
            return [
                AgentModeOption(id: "plan", displayName: "Plan"),
                AgentModeOption(id: "default", displayName: "Default"),
                AgentModeOption(id: "accept-edits", displayName: "Accept edits"),
                AgentModeOption(id: "auto", displayName: "Auto")
            ]
        }
        if token.contains("claude") {
            return [
                AgentModeOption(id: "plan", displayName: "Plan"),
                AgentModeOption(id: "default", displayName: "Manual"),
                AgentModeOption(id: "acceptEdits", displayName: "Accept edits"),
                AgentModeOption(id: "auto", displayName: "Auto"),
                AgentModeOption(id: "bypassPermissions", displayName: "Bypass permissions")
            ]
        }
        if token.contains("codex") {
            return [
                AgentModeOption(id: "read-only", displayName: "Read-only"),
                AgentModeOption(id: "agent", displayName: "Agent"),
                AgentModeOption(id: "agent-auto-review", displayName: "Agent (auto review)"),
                AgentModeOption(id: "agent-full-access", displayName: "Agent (full access)")
            ]
        }
        return []
    }

    /// 尝试映射到底层本地 CLI 引擎类型（用于在离线或模型列表为空时提供智能回退）
    public var inferredUnderlyingEngine: AgentEngine? {
        let token = (agentType ?? name).lowercased()
        if token.contains("claude") { return .claudeCode }
        if token.contains("codex") { return .codex }
        if token.contains("antigravity") || token.contains("agy") { return .antigravity }
        return nil
    }

    public static let fallbackPresets: [LodyAgentConfigOption] = [
        LodyAgentConfigOption(
            id: "antigravity",
            name: "Antigravity",
            agentType: "antigravity",
            models: [],
            effortOptionKey: "thought_level",
            reasoningEffortValues: ["low", "medium", "high", "xhigh"],
            readOnlyModeID: "plan"
        ),
        LodyAgentConfigOption(
            id: "claude",
            name: "Claude Code",
            agentType: "claude",
            models: [],
            effortOptionKey: "effort",
            reasoningEffortValues: ["low", "medium", "high", "xhigh", "max"],
            readOnlyModeID: "plan"
        ),
        LodyAgentConfigOption(
            id: "codex",
            name: "Codex",
            agentType: "codex",
            models: [],
            effortOptionKey: "reasoning_effort",
            reasoningEffortValues: ["low", "medium", "high", "xhigh", "max"],
            readOnlyModeID: "read-only"
        )
    ]
}

public struct LodyLocalProjectOption: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let rootPath: String
    /// 从 `<rootPath>/.git/config` 推导出的 `owner/repo`（小写）
    public let repositoryFullName: String?

    public init(id: String, name: String, rootPath: String, repositoryFullName: String? = nil) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.repositoryFullName = repositoryFullName
    }
}

/// 派发到 Lody 会话时的代码工作区路由目标（关联 ADR-007, ITER-010）
public enum LodyWorkspaceTarget: Equatable, Sendable {
    /// 命中 Lody 已注册本地项目（优先使用，按需 --worktree --branch 隔离审查）
    case localProject(idOrPath: String, useWorktree: Bool, branch: String?)
    /// 命中 Lody 云端已绑定的 GitHub 仓库
    case linkedGitHubRepo(fullName: String, branch: String?)
    /// 兜底：由 CollabDock 创建本地隔离 Worktree 后把路径传给 --local-project
    case preparedLocalPath(String)
}

public struct LodyCatalogSnapshot: Codable, Equatable, Sendable {
    public let workspaceID: String?
    public let workspaces: [LodyWorkspaceOption]
    public let agentConfigs: [LodyAgentConfigOption]
    public let localProjects: [LodyLocalProjectOption]
    public let linkedGitHubRepos: [String]
    public let fetchedAt: Date

    public init(
        workspaceID: String? = nil,
        workspaces: [LodyWorkspaceOption] = [],
        agentConfigs: [LodyAgentConfigOption] = [],
        localProjects: [LodyLocalProjectOption] = [],
        linkedGitHubRepos: [String] = [],
        fetchedAt: Date = Date()
    ) {
        self.workspaceID = workspaceID
        self.workspaces = workspaces
        self.agentConfigs = agentConfigs
        self.localProjects = localProjects
        self.linkedGitHubRepos = linkedGitHubRepos
        self.fetchedAt = fetchedAt
    }

    enum CodingKeys: String, CodingKey {
        case workspaceID, workspaces, agentConfigs, localProjects, linkedGitHubRepos, fetchedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.workspaceID = try? c.decodeIfPresent(String.self, forKey: .workspaceID)
        self.workspaces = (try? c.decodeIfPresent([LodyWorkspaceOption].self, forKey: .workspaces)) ?? []
        self.agentConfigs = (try? c.decodeIfPresent([LodyAgentConfigOption].self, forKey: .agentConfigs)) ?? []
        self.localProjects = (try? c.decodeIfPresent([LodyLocalProjectOption].self, forKey: .localProjects)) ?? []
        self.linkedGitHubRepos = (try? c.decodeIfPresent([String].self, forKey: .linkedGitHubRepos)) ?? []
        self.fetchedAt = (try? c.decodeIfPresent(Date.self, forKey: .fetchedAt)) ?? Date()
    }

    public var totalModelCount: Int {
        agentConfigs.reduce(0) { $0 + $1.models.count }
    }

    /// 优先按 git origin `owner/repo` 匹配 Lody 本地项目，其次按仓库短名匹配
    public func matchLocalProject(forRepository repoFullName: String) -> LodyLocalProjectOption? {
        let target = repoFullName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return nil }
        if let exact = localProjects.first(where: { $0.repositoryFullName?.lowercased() == target }) {
            return exact
        }
        let shortName = target.split(separator: "/").last.map(String.init) ?? target
        return localProjects.first(where: { $0.name.lowercased() == shortName })
    }

    public func hasLinkedGitHubRepo(_ repoFullName: String) -> Bool {
        let target = repoFullName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return linkedGitHubRepos.contains(where: { $0.lowercased() == target })
    }

    /// 根据 id、name 或 agentType 匹配对应的 Lody Agent Config（兼容旧别名如 claude/codex/antigravity）
    public func matchAgentConfig(selector: String) -> LodyAgentConfigOption? {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "default" else { return nil }
        let lowered = trimmed.lowercased()
        if let exact = agentConfigs.first(where: { $0.id == trimmed }) {
            return exact
        }
        if let byName = agentConfigs.first(where: { $0.name.lowercased() == lowered }) {
            return byName
        }
        if let byType = agentConfigs.first(where: { $0.agentType?.lowercased() == lowered }) {
            return byType
        }
        return nil
    }

    /// 统一解析某个 Lody Agent Config 下的可选模型列表（优先真实 Lody 能力，否则优雅回退到底层本机探测模型）
    public static func resolveModels(
        forAgentConfig selector: String,
        catalog: LodyCatalogSnapshot?,
        fallbackByEngine: [AgentEngine: [ModelOption]]
    ) -> [ModelOption] {
        let defaultFollow = ModelOption(id: "default", displayName: "跟随 Agent 默认模型")
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty || trimmed == "default" {
            return [ModelOption(id: "default", displayName: "跟随 Workspace 默认模型")]
        }

        if let matched = catalog?.matchAgentConfig(selector: trimmed) {
            if !matched.models.isEmpty {
                let hasDefault = matched.models.contains(where: { $0.id == "default" })
                return hasDefault ? matched.models : ([defaultFollow] + matched.models)
            }
            if let underlying = matched.inferredUnderlyingEngine {
                let fallback = fallbackByEngine[underlying] ?? underlying.defaultModels
                return [defaultFollow] + fallback
            }
            return [defaultFollow]
        }

        // 未连上 Lody 目录前的回退推断
        let lowered = trimmed.lowercased()
        if lowered.contains("claude") {
            return [defaultFollow] + (fallbackByEngine[.claudeCode] ?? AgentEngine.claudeCode.defaultModels)
        }
        if lowered.contains("codex") {
            return [defaultFollow] + (fallbackByEngine[.codex] ?? AgentEngine.codex.defaultModels)
        }
        if lowered.contains("antigravity") || lowered.contains("agy") {
            return [defaultFollow] + (fallbackByEngine[.antigravity] ?? AgentEngine.antigravity.defaultModels)
        }
        return [defaultFollow]
    }

    /// 统一解析某个 Lody Agent Config 下可选的 ACP Mode 列表（关联 ITER-016）
    public static func resolveModes(
        forAgentConfig selector: String,
        catalog: LodyCatalogSnapshot?
    ) -> [AgentModeOption] {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "default" else {
            return AgentEngine.lody.defaultModes
        }
        if let matched = catalog?.matchAgentConfig(selector: trimmed), !matched.modes.isEmpty {
            return matched.modes
        }
        let fallback = LodyAgentConfigOption.fallbackModes(forAgentType: trimmed)
        return fallback.isEmpty ? AgentEngine.lody.defaultModes : fallback
    }
}

public enum ReasoningEffort: String, CaseIterable, Codable, Sendable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        case .max: return "Max"
        }
    }
}

public enum ExecutionSandboxPolicy: String, Codable, Hashable, Sendable {
    case readOnly
}

/// 唤起本地 AI 的驱动方式（关联 ADR-006）
public enum ExecutionLaunchMode: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// 持久化无头执行 + 流式进度 + JSON Schema 自动交付草稿，同时保留 sessionID 供随时接管
    case managedStructuredRun
    /// 直接派发为引擎原生后台会话（如 claude --bg / 未来 codex app-server / agy acp）
    case nativeBackgroundSession

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .managedStructuredRun:
            return "托管执行并生成草稿（可随时接管会话）"
        case .nativeBackgroundSession:
            return "派发为原生后台会话（类定时任务）"
        }
    }

    public var shortLabel: String {
        switch self {
        case .managedStructuredRun:
            return "托管并生成草稿"
        case .nativeBackgroundSession:
            return "原生后台会话"
        }
    }
}

/// 跨平台通用交付模式（由各 Connector 决定支持子集，关联 ADR-004, ADR-005）
public enum DeliveryMode: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// 平台原生草稿（如 GitHub / GitLab Pending Review）
    case platformDraft
    /// 仅在本地生成报告/回复草稿（可一键复制或审阅）
    case localDraftOnly
    /// 直接回复到源平台评论/话题
    case directReply

    public var id: String { rawValue }

    public func displayName(for platform: PlatformKind) -> String {
        switch self {
        case .platformDraft:
            return "\(platform.displayName) Pending 草稿（推荐，仅自己可见）"
        case .localDraftOnly:
            return "仅本地生成草稿/报告"
        case .directReply:
            return "直接回复到 \(platform.displayName)"
        }
    }

    public func shortLabel(for platform: PlatformKind) -> String {
        switch self {
        case .platformDraft:
            return "Pending 草稿"
        case .localDraftOnly:
            return "仅本地草稿"
        case .directReply:
            return "直接回复"
        }
    }
}

public enum CollaborationTaskStatus: String, Codable, Hashable, Sendable {
    case pendingConfirmation
    case preparing
    case running
    case publishing
    case draftReady
    case completed
    case failed
    case dismissed

    /// 邮件式分栏语义：所有尚需关注或操作的状态（待确认、运行中、待审草稿、失败待重试）均保留在「收件箱」；仅「已完成 / 已忽略」归档到「已完成」
    public var isInboxActive: Bool {
        switch self {
        case .pendingConfirmation, .preparing, .running, .publishing, .draftReady, .failed:
            return true
        case .completed, .dismissed:
            return false
        }
    }
}

/// 异步派发后台会话（如 Lody）的实时远端执行状态（关联 ITER-015）
public enum RemoteSessionStatus: String, Codable, Hashable, Sendable {
    case running
    case completed
    case failed
}

/// 事项归档至「已完成」的原因（用于区分手动完成与 GitHub Approve / 合并 / 关闭自动归档，关联 ITER-017）
public enum TaskCompletionReason: String, Codable, Hashable, Sendable {
    case manual
    case prApproved
    case prMerged
    case prClosed

    public var displayLabel: String {
        switch self {
        case .manual: return "已完成"
        case .prApproved: return "已 Approve"
        case .prMerged: return "已合并"
        case .prClosed: return "已关闭"
        }
    }
}

/// 同 PR 历史审查上下文（用于自动识别复审、原会话续聊与增量 Commit Diff，关联 REQ-010, TASK-015, ITER-013）
public struct PreviousReviewContext: Codable, Hashable, Sendable {
    public let previousItemID: String
    public let reviewedHeadSHA: String
    public let reviewedAt: Date
    public let engine: AgentEngine
    public let model: String?
    public let sessionID: String?
    public let summarySnippet: String?
    public let reviewRound: Int

    public init(
        previousItemID: String,
        reviewedHeadSHA: String,
        reviewedAt: Date,
        engine: AgentEngine,
        model: String? = nil,
        sessionID: String? = nil,
        summarySnippet: String? = nil,
        reviewRound: Int = 1
    ) {
        self.previousItemID = previousItemID
        self.reviewedHeadSHA = reviewedHeadSHA
        self.reviewedAt = reviewedAt
        self.engine = engine
        self.model = model
        self.sessionID = sessionID
        self.summarySnippet = summarySnippet
        self.reviewRound = reviewRound
    }

    public var canContinueSameSession: Bool {
        guard let sid = sessionID, !sid.isEmpty else { return false }
        return engine == .lody || engine == .claudeCode || engine == .antigravity
    }
}

/// 重复审查（开发修复后再次叫你 Review）的执行策略（关联 REQ-010, TASK-015, ITER-013）
public enum ReviewContinuityMode: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    /// 续聊原会话 + 仅聚焦上次审查后的增量 Commit Diff（保留上轮记忆）
    case continueSessionIncremental
    /// 新开会话，聚焦增量 Commit Diff 并附带上轮结论摘要
    case freshSessionIncremental
    /// 新开会话，重新全量审查整个 PR
    case freshSessionFull

    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .continueSessionIncremental: return "续聊原会话 · 增量 Diff"
        case .freshSessionIncremental: return "新开会话 · 增量 Diff"
        case .freshSessionFull: return "新开会话 · 全量 PR"
        }
    }

    public var displayName: String {
        switch self {
        case .continueSessionIncremental: return "续聊原会话 · 仅审新增改动（推荐，保留上轮记忆）"
        case .freshSessionIncremental: return "新开会话 · 仅审新增改动（附带上次摘要）"
        case .freshSessionFull: return "新开会话 · 全量重审整个 PR"
        }
    }
}

/// 统一协作任务项（替代 GitHub-only 的 ReviewTask）
public struct CollaborationItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let platform: PlatformKind
    public let itemKind: CollaborationItemKind
    /// 所属作用域容器：GitHub/GitLab 仓库名、飞书/Slack 群名、Linear Team 等
    public let scope: String
    /// 平台展示编号：如 "#482"、"ENG-1024"、"Thread"
    public let externalRef: String
    public let title: String
    public let url: URL
    public let author: String
    public let triggeredBy: String
    public let triggerKind: TriggerKind
    public let triggerBody: String?
    public let payload: CollaborationPayload
    public let createdAt: Date
    public var status: CollaborationTaskStatus
    public var suggestedEngine: AgentEngine?
    public var suggestedModel: String?
    public var suggestedPresetID: String?
    public var progressMessage: String?
    public var sessionID: String?
    public var sessionHandle: AgentSessionHandle?
    public var localReportPath: String?
    public var deliveryURL: URL?
    public var executionOutput: ExecutionOutput?
    public var errorMessage: String?
    /// 若同一 PR / 任务此前已审查过，记录上一轮的 SHA、会话 ID 与摘要以支持复审续聊
    public var previousReview: PreviousReviewContext?
    public var reviewRound: Int
    /// Lody 等异步后台会话的远端实时状态（审查中 / 审查完成 / 执行异常）
    public var remoteSessionStatus: RemoteSessionStatus?
    /// 归档完成原因（如 `已 Approve` / `已合并` / `已关闭` / `手动完成`）
    public var completionReason: TaskCompletionReason?
    /// 远端 PR 审查状态辅助提示（如你已提交 `CHANGES_REQUESTED`，留在收件箱待作者修复）
    public var gitHubReviewVerdict: String?

    public init(
        id: String,
        platform: PlatformKind,
        itemKind: CollaborationItemKind,
        scope: String,
        externalRef: String,
        title: String,
        url: URL,
        author: String,
        triggeredBy: String,
        triggerKind: TriggerKind,
        triggerBody: String? = nil,
        payload: CollaborationPayload,
        createdAt: Date = Date(),
        status: CollaborationTaskStatus = .pendingConfirmation,
        suggestedEngine: AgentEngine? = nil,
        suggestedModel: String? = nil,
        suggestedPresetID: String? = nil,
        progressMessage: String? = nil,
        sessionID: String? = nil,
        sessionHandle: AgentSessionHandle? = nil,
        localReportPath: String? = nil,
        deliveryURL: URL? = nil,
        executionOutput: ExecutionOutput? = nil,
        errorMessage: String? = nil,
        previousReview: PreviousReviewContext? = nil,
        reviewRound: Int = 1,
        remoteSessionStatus: RemoteSessionStatus? = nil,
        completionReason: TaskCompletionReason? = nil,
        gitHubReviewVerdict: String? = nil
    ) {
        self.id = id
        self.platform = platform
        self.itemKind = itemKind
        self.scope = scope
        self.externalRef = externalRef
        self.title = title
        self.url = url
        self.author = author
        self.triggeredBy = triggeredBy
        self.triggerKind = triggerKind
        self.triggerBody = triggerBody
        self.payload = payload
        self.createdAt = createdAt
        self.status = status
        self.suggestedEngine = suggestedEngine
        self.suggestedModel = suggestedModel
        self.suggestedPresetID = suggestedPresetID
        self.progressMessage = progressMessage
        self.sessionID = sessionID
        self.sessionHandle = sessionHandle
        self.localReportPath = localReportPath
        self.deliveryURL = deliveryURL
        self.executionOutput = executionOutput
        self.errorMessage = errorMessage
        self.previousReview = previousReview
        self.reviewRound = reviewRound
        self.remoteSessionStatus = remoteSessionStatus
        self.completionReason = completionReason
        self.gitHubReviewVerdict = gitHubReviewVerdict
    }

    enum CodingKeys: String, CodingKey {
        case id, platform, itemKind, scope, externalRef, title, url, author
        case triggeredBy, triggerKind, triggerBody, payload, createdAt, status
        case suggestedEngine, suggestedModel, suggestedPresetID, progressMessage
        case sessionID, sessionHandle, localReportPath, deliveryURL
        case executionOutput, errorMessage, previousReview, reviewRound
        case remoteSessionStatus, completionReason, gitHubReviewVerdict
    }

    /// 向后兼容解码：SQLite 旧行缺少新增字段时平滑补默认值
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.platform = try c.decode(PlatformKind.self, forKey: .platform)
        self.itemKind = try c.decode(CollaborationItemKind.self, forKey: .itemKind)
        self.scope = try c.decode(String.self, forKey: .scope)
        self.externalRef = try c.decode(String.self, forKey: .externalRef)
        self.title = try c.decode(String.self, forKey: .title)
        self.url = try c.decode(URL.self, forKey: .url)
        self.author = try c.decode(String.self, forKey: .author)
        self.triggeredBy = try c.decode(String.self, forKey: .triggeredBy)
        self.triggerKind = try c.decode(TriggerKind.self, forKey: .triggerKind)
        self.triggerBody = try c.decodeIfPresent(String.self, forKey: .triggerBody)
        self.payload = try c.decode(CollaborationPayload.self, forKey: .payload)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.status = try c.decode(CollaborationTaskStatus.self, forKey: .status)
        self.suggestedEngine = try c.decodeIfPresent(AgentEngine.self, forKey: .suggestedEngine)
        self.suggestedModel = try c.decodeIfPresent(String.self, forKey: .suggestedModel)
        self.suggestedPresetID = try c.decodeIfPresent(String.self, forKey: .suggestedPresetID)
        self.progressMessage = try c.decodeIfPresent(String.self, forKey: .progressMessage)
        self.sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        self.sessionHandle = try c.decodeIfPresent(AgentSessionHandle.self, forKey: .sessionHandle)
        self.localReportPath = try c.decodeIfPresent(String.self, forKey: .localReportPath)
        self.deliveryURL = try c.decodeIfPresent(URL.self, forKey: .deliveryURL)
        self.executionOutput = try c.decodeIfPresent(ExecutionOutput.self, forKey: .executionOutput)
        self.errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        self.previousReview = try c.decodeIfPresent(PreviousReviewContext.self, forKey: .previousReview)
        self.reviewRound = (try? c.decodeIfPresent(Int.self, forKey: .reviewRound)) ?? 1
        self.remoteSessionStatus = try? c.decodeIfPresent(RemoteSessionStatus.self, forKey: .remoteSessionStatus)
        self.completionReason = try? c.decodeIfPresent(TaskCompletionReason.self, forKey: .completionReason)
        self.gitHubReviewVerdict = try? c.decodeIfPresent(String.self, forKey: .gitHubReviewVerdict)
    }

    public var displayContextTag: String {
        externalRef.isEmpty ? scope : "\(scope) \(externalRef)"
    }
}

/// 多模型会诊搭档配置（关联 REQ-010, TASK-017）
public struct CouncilPartner: Codable, Hashable, Sendable {
    public var engine: AgentEngine
    public var model: String
    public var effort: ReasoningEffort

    public init(engine: AgentEngine, model: String, effort: ReasoningEffort = .high) {
        self.engine = engine
        self.model = model
        self.effort = effort
    }
}

/// 本地人工确认后生成的执行计划（关联 REQ-005, REQ-010, ADR-006, ADR-007, ITER-012）
public struct ExecutionPlan: Codable, Hashable, Sendable {
    public var engine: AgentEngine
    /// 实际传给 AI 引擎或 Lody `--model` 的模型 ID（`"default"` 表示跟随 Agent 默认模型）
    public var model: String
    /// 仅当 `engine == .lody` 时生效：目标 Lody Agent Config 的 ID 或名称（`"default"` / `nil` 表示跟随 Workspace 默认 Agent）
    public var lodyAgentConfig: String?
    public var effort: ReasoningEffort
    /// 可选执行模式（如 Lody/Antigravity/Claude 的 `plan`/`default`/`accept-edits`/`auto`，或 Codex 的 `read-only`/`agent`/`workspace-write`）
    public var mode: String?
    public var presetID: String
    public var deliveryMode: DeliveryMode
    public var launchMode: ExecutionLaunchMode
    public var sandboxPolicy: ExecutionSandboxPolicy
    /// 可选：本次任务临时指定或覆写的本地项目目录路径（nil 表示按仓库映射自动解析）
    public var targetDirectoryOverride: String?
    /// 是否使用独立 Git Worktree 隔离审查（默认 true，绝不切掉当前开发分支；设为 false 则直接在项目主目录中运行）
    public var useIsolatedWorktree: Bool
    /// 同 PR 复审策略（首次审查恒为 freshSessionFull；检测到历史审查时可续聊原会话或只审增量 Diff）
    public var continuityMode: ReviewContinuityMode
    /// 关联的上一轮审查上下文（用于续聊会话 ID 与增量 Diff 基线 SHA）
    public var previousReview: PreviousReviewContext?
    public var extraInstructions: String
    /// 可选：启用双引擎并行会诊时的第二引擎配置（共享同一只读 Worktree）
    public var councilPartner: CouncilPartner?

    public init(
        engine: AgentEngine,
        model: String,
        lodyAgentConfig: String? = nil,
        effort: ReasoningEffort = .high,
        mode: String? = nil,
        presetID: String = "code-review-general",
        deliveryMode: DeliveryMode = .platformDraft,
        launchMode: ExecutionLaunchMode = .managedStructuredRun,
        sandboxPolicy: ExecutionSandboxPolicy = .readOnly,
        targetDirectoryOverride: String? = nil,
        useIsolatedWorktree: Bool = true,
        continuityMode: ReviewContinuityMode = .freshSessionFull,
        previousReview: PreviousReviewContext? = nil,
        extraInstructions: String = "",
        councilPartner: CouncilPartner? = nil
    ) {
        self.engine = engine
        self.model = model
        self.lodyAgentConfig = lodyAgentConfig
        self.effort = effort
        self.mode = mode
        self.presetID = presetID
        self.deliveryMode = deliveryMode
        self.launchMode = launchMode
        self.sandboxPolicy = sandboxPolicy
        self.targetDirectoryOverride = targetDirectoryOverride
        self.useIsolatedWorktree = useIsolatedWorktree
        self.continuityMode = continuityMode
        self.previousReview = previousReview
        self.extraInstructions = extraInstructions
        self.councilPartner = councilPartner
    }
}

// MARK: - 统一执行产出（支持代码行级审查与通用协作回复）

public enum ReviewVerdict: String, Codable, Sendable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
}

public enum FindingSeverity: String, Codable, Sendable {
    case critical
    case warning
    case nit
}

public enum DiffSide: String, Codable, Sendable {
    case left = "LEFT"
    case right = "RIGHT"
}

public struct CodeInlineComment: Codable, Hashable, Sendable {
    public let path: String
    public let line: Int
    public let side: DiffSide
    public let severity: FindingSeverity
    public let title: String
    public let body: String
    public let suggestion: String?

    public init(
        path: String,
        line: Int,
        side: DiffSide = .right,
        severity: FindingSeverity,
        title: String,
        body: String,
        suggestion: String? = nil
    ) {
        self.path = path
        self.line = line
        self.side = side
        self.severity = severity
        self.title = title
        self.body = body
        self.suggestion = suggestion
    }
}

public struct CodeReviewResult: Codable, Hashable, Sendable {
    public let summary: String
    public let recommendedVerdict: ReviewVerdict
    public let comments: [CodeInlineComment]

    public init(
        summary: String,
        recommendedVerdict: ReviewVerdict,
        comments: [CodeInlineComment]
    ) {
        self.summary = summary
        self.recommendedVerdict = recommendedVerdict
        self.comments = comments
    }

    public var criticalCount: Int { comments.filter { $0.severity == .critical }.count }
    public var warningCount: Int { comments.filter { $0.severity == .warning }.count }
    public var nitCount: Int { comments.filter { $0.severity == .nit }.count }
}

public struct StructuredReplyResult: Codable, Hashable, Sendable {
    public let summary: String
    public let replyMarkdown: String
    public let keyPoints: [String]
    public let referencedFiles: [String]

    public init(
        summary: String,
        replyMarkdown: String,
        keyPoints: [String] = [],
        referencedFiles: [String] = []
    ) {
        self.summary = summary
        self.replyMarkdown = replyMarkdown
        self.keyPoints = keyPoints
        self.referencedFiles = referencedFiles
    }
}

public enum ExecutionOutput: Codable, Hashable, Sendable {
    case codeReview(CodeReviewResult)
    case structuredReply(StructuredReplyResult)

    public var summaryText: String {
        switch self {
        case .codeReview(let r): return r.summary
        case .structuredReply(let r): return r.summary
        }
    }
}
