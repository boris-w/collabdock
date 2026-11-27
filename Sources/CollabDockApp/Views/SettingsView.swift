import AppKit
import SwiftUI
import CollabDockCore

struct SettingsView: View {
    enum SettingsTab: Hashable {
        case connectors
        case triggerRules
        case engines
        case workspaces
        case teamAndGeneral
        case stats
    }

    @Bindable var coordinator: AppCoordinator
    @State private var selectedTab: SettingsTab
    @State private var copiedHint: String?
    @State private var useCustomLodyAgentConfig: Bool = false
    @State private var useCustomLodyWorkspace: Bool = false
    @State private var newRepoKeyInput: String = ""
    @State private var versionTapCount: Int = 0
    @State private var lastVersionTapAt: Date = .distantPast
    @State private var devModeToast: String? = nil

    private var appVersionLabel: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "v\(ver?.isEmpty == false ? ver! : "0.1.0")"
    }

    init(coordinator: AppCoordinator, initialTab: SettingsTab = .connectors) {
        self.coordinator = coordinator
        self._selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            connectorsTab
                .tabItem { Label("协作来源", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(SettingsTab.connectors)
            triggerRulesTab
                .tabItem { Label("触发规则", systemImage: "line.3.horizontal.decrease.circle") }
                .tag(SettingsTab.triggerRules)
            enginesTab
                .tabItem { Label("AI 引擎", systemImage: "cpu") }
                .tag(SettingsTab.engines)
            workspacesTab
                .tabItem { Label("工作区", systemImage: "folder") }
                .tag(SettingsTab.workspaces)
            teamAndGeneralTab
                .tabItem { Label("提示词与团队", systemImage: "text.badge.star") }
                .tag(SettingsTab.teamAndGeneral)
            UsageStatsSettingsView(coordinator: coordinator)
                .tabItem { Label("用量统计", systemImage: "chart.bar.xaxis") }
                .tag(SettingsTab.stats)
        }
        .frame(width: 680, height: 560)
        .padding(12)
        .onAppear {
            syncCustomFlagsFromSettings()
            if let requested = coordinator.requestedSettingsTab {
                selectedTab = requested
                coordinator.requestedSettingsTab = nil
            }
        }
        .onChange(of: coordinator.requestedSettingsTab) { _, requested in
            if let requested {
                selectedTab = requested
                coordinator.requestedSettingsTab = nil
            }
        }
        .onChange(of: coordinator.lodyCatalog?.fetchedAt) { _, _ in
            syncCustomFlagsFromSettings()
        }
        .background {
            // 隐藏快捷键 ⌘⇧D：随时切换开发者模式（关联 ITER-015）
            Button("") {
                toggleDeveloperModeWithFeedback()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private func syncCustomFlagsFromSettings() {
        let currentAgent = coordinator.settings.lodyConfig.defaultAgentConfig
        let knownAgentIDs = Set(["default"] + coordinator.lodyAgentConfigOptions.map(\.id))
        let matchesKnown = knownAgentIDs.contains(currentAgent)
            || coordinator.lodyCatalog?.matchAgentConfig(selector: currentAgent) != nil
        useCustomLodyAgentConfig = !currentAgent.isEmpty && !matchesKnown

        let currentWS = coordinator.settings.lodyConfig.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let knownWS = coordinator.lodyCatalog?.workspaces ?? []
        useCustomLodyWorkspace = !currentWS.isEmpty && !knownWS.contains(where: { $0.id == currentWS || $0.slug == currentWS || $0.name == currentWS })
    }

    // MARK: - 1. 协作来源

    private var connectorsTab: some View {
        Form {
            Section("GitHub 实时认证状态") {
                if let auth = coordinator.environment?.githubAuth {
                    HStack(spacing: 12) {
                        if auth.isAuthenticated {
                            ZStack(alignment: .bottomTrailing) {
                                if let img = coordinator.githubAvatarImage {
                                    Image(nsImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 34, height: 34)
                                        .clipShape(Circle())
                                        .overlay(
                                            Circle().strokeBorder(Color.secondary.opacity(0.22), lineWidth: 0.6)
                                        )
                                } else {
                                    Circle()
                                        .fill(Color.secondary.opacity(0.14))
                                        .frame(width: 34, height: 34)
                                        .overlay(
                                            Text(String((auth.displayName ?? auth.username ?? "G").prefix(1)).uppercased())
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        )
                                }
                                Circle()
                                    .fill(CDTheme.statusGreen)
                                    .frame(width: 10, height: 10)
                                    .overlay(
                                        Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5)
                                    )
                            }
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title3)
                                .foregroundStyle(CDTheme.statusAmber)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            if auth.isAuthenticated {
                                let login = auth.username ?? coordinator.resolvedGitHubUsername
                                HStack(spacing: 6) {
                                    if let alias = auth.displayName, !alias.isEmpty, alias.lowercased() != login.lowercased() {
                                        Text(alias)
                                            .font(.subheadline.weight(.semibold))
                                        Text("@\(login)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("@\(login)")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    Text(auth.tokenSource == .ghCLI ? "gh CLI" : "PAT")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5.5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.secondary.opacity(0.12), in: Capsule())
                                }
                                Text(auth.hasNotificationsScope ? "已具备 notifications 权限（304 零配额快速通道已启用）" : "当前 Token 缺少 notifications 权限，已按 180s 低频自动走 Search API 降级")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let rl = coordinator.latestRateLimit {
                                    Text("API 剩余配额：\(rl.remaining) / \(rl.limit)\(coordinator.lastSyncWas304 ? " · 上次 304 零消耗" : "")")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            } else {
                                Text(auth.errorMessage ?? "未登录 GitHub")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        Spacer()
                        Button("立即同步") {
                            coordinator.refreshNow()
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)

                    if auth.isAuthenticated && !auth.hasNotificationsScope {
                        HStack {
                            Text("gh auth refresh -s notifications")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(copiedHint == "gh-refresh" ? "已复制" : "复制升级命令") {
                                copyToPasteboard("gh auth refresh -s notifications", tag: "gh-refresh")
                            }
                            .controlSize(.small)
                        }
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在检测本机 GitHub 认证状态...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("可插拔协作连接器") {
                ForEach($coordinator.settings.connectors) { $connector in
                    let caps = ConnectorCatalog.capabilities(for: connector.platform)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: connector.platform.symbolName)
                                .foregroundStyle(connector.platform.accentColor)
                                .frame(width: 18)
                            Text(connector.platform.displayName)
                                .font(.body.weight(.medium))
                            if !caps.isImplementedInV1 {
                                Text("架构已抽象 · 规划中")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                            Spacer()
                            Toggle("", isOn: $connector.isEnabled)
                                .labelsHidden()
                                .disabled(!caps.isImplementedInV1)
                        }
                        Text(caps.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if connector.isEnabled {
                            HStack {
                                Text("账号标识")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                TextField(
                                    "",
                                    text: $connector.accountHandle,
                                    prompt: Text("留空自动从 gh auth 获取")
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 2. 触发规则

    private var triggerRulesTab: some View {
        Form {
            Section("全局触发来源（可自由手动组合开关）") {
                Toggle("评论 / 消息中 @我 (mention)", isOn: $coordinator.settings.globalTriggerRules.enableMention)
                Toggle("代码审查指派 (review_requested)", isOn: $coordinator.settings.globalTriggerRules.enableReviewRequested)
                Toggle("任务 / 工单指派给我 (assigned)", isOn: $coordinator.settings.globalTriggerRules.enableAssigned)
                Toggle("团队指派 / Team Mention", isOn: $coordinator.settings.globalTriggerRules.enableTeamMention)
            }

            Section("@mention 关键词与建议解析") {
                Toggle("要求包含触发关键词（避免普通闲聊打扰）", isOn: $coordinator.settings.globalTriggerRules.requireMentionKeywords)
                labeledInputRow(
                    title: "触发关键词",
                    placeholder: "例如 review, cr, 帮忙看, check",
                    text: Binding(
                        get: { coordinator.settings.globalTriggerRules.mentionKeywords.joined(separator: ", ") },
                        set: { raw in
                            coordinator.settings.globalTriggerRules.mentionKeywords = raw
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                        }
                    )
                )
                .disabled(!coordinator.settings.globalTriggerRules.requireMentionKeywords)

                Toggle("解析触发正文中的 --model / --focus 建议（仅预填，不绕过人工确认）", isOn: $coordinator.settings.globalTriggerRules.parseTriggerHints)
            }

            Section("自动归档规则") {
                Toggle("PR 在 GitHub 被 Approve、合并或关闭后自动归档至「已完成」", isOn: $coordinator.settings.autoCompleteApprovedOrClosedPRs)
                Text("通过单次批量 GraphQL 轻量对齐（收件箱为空时零请求）。仅对 Approved / Merged / Closed 自动归档；提交 Request Changes 的 PR 会保留在收件箱（标示「待修复」）继续跟进。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("作用域与降噪过滤") {
                Toggle("忽略 Draft PR / 草稿项", isOn: $coordinator.settings.globalTriggerRules.ignoreDraftItems)
                Toggle("忽略 Bot 账号触发", isOn: $coordinator.settings.globalTriggerRules.ignoreBots)
                labeledInputRow(
                    title: "作用域白名单",
                    placeholder: "如 org/*, #oncall*（留空表示不限）",
                    text: Binding(
                        get: { coordinator.settings.globalTriggerRules.scopeAllowlist.joined(separator: ", ") },
                        set: { raw in
                            coordinator.settings.globalTriggerRules.scopeAllowlist = raw
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                        }
                    )
                )
                labeledInputRow(
                    title: "作用域黑名单",
                    placeholder: "如 org/sandbox（优先级高于白名单）",
                    text: Binding(
                        get: { coordinator.settings.globalTriggerRules.scopeDenylist.joined(separator: ", ") },
                        set: { raw in
                            coordinator.settings.globalTriggerRules.scopeDenylist = raw
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                        }
                    )
                )
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 3. AI 引擎与本机体检

    private var enginesTab: some View {
        let activeEngine = coordinator.settings.defaultEngine
        let lodyAgents = coordinator.lodyAgentConfigOptions
        let currentLodyAgent = coordinator.settings.lodyConfig.defaultAgentConfig
        let lodyModels = coordinator.modelsForLody(agentConfig: currentLodyAgent)
        let directModels = coordinator.availableModelsByEngine[activeEngine] ?? activeEngine.defaultModels

        let directModelBinding = Binding<String>(
            get: {
                let current = coordinator.settings.defaultModels[activeEngine] ?? ""
                if directModels.contains(where: { $0.id == current }) {
                    return current
                }
                return directModels.first?.id ?? ""
            },
            set: { newValue in
                coordinator.settings.defaultModels[activeEngine] = newValue
            }
        )

        let lodyAgentSelectionBinding = Binding<String>(
            get: {
                if useCustomLodyAgentConfig {
                    return "__custom__"
                }
                let raw = coordinator.settings.lodyConfig.defaultAgentConfig
                if raw.isEmpty || raw == "default" {
                    return "default"
                }
                if let matched = lodyAgents.first(where: {
                    $0.id == raw || $0.name.lowercased() == raw.lowercased() || $0.agentType?.lowercased() == raw.lowercased()
                }) {
                    return matched.id
                }
                return "__custom__"
            },
            set: { newValue in
                if newValue == "__custom__" {
                    useCustomLodyAgentConfig = true
                    let raw = coordinator.settings.lodyConfig.defaultAgentConfig
                    if raw == "default" || lodyAgents.contains(where: { $0.id == raw }) {
                        coordinator.settings.lodyConfig.defaultAgentConfig = ""
                    }
                } else {
                    useCustomLodyAgentConfig = false
                    coordinator.settings.lodyConfig.defaultAgentConfig = newValue
                    // 切换 Lody Agent 后自动对齐到该 Agent 偏好的有效模型与模式
                    let preferred = coordinator.preferredLodyModel(forAgentConfig: newValue)
                    coordinator.setPreferredLodyModel(preferred, forAgentConfig: newValue)
                    let preferredMode = coordinator.preferredLodyMode(forAgentConfig: newValue)
                    coordinator.setPreferredLodyMode(preferredMode, forAgentConfig: newValue)
                }
            }
        )

        let lodyModelBinding = Binding<String>(
            get: {
                let preferred = coordinator.preferredLodyModel(forAgentConfig: currentLodyAgent)
                if lodyModels.contains(where: { $0.id == preferred }) {
                    return preferred
                }
                return lodyModels.first?.id ?? "default"
            },
            set: { newValue in
                coordinator.setPreferredLodyModel(newValue, forAgentConfig: currentLodyAgent)
            }
        )

        let lodyModes = coordinator.modesForLody(agentConfig: currentLodyAgent)
        let lodyModeBinding = Binding<String>(
            get: {
                let preferred = coordinator.preferredLodyMode(forAgentConfig: currentLodyAgent)
                if lodyModes.contains(where: { $0.id == preferred }) {
                    return preferred
                }
                return lodyModes.first?.id ?? "__agent_default__"
            },
            set: { newValue in
                coordinator.setPreferredLodyMode(newValue, forAgentConfig: currentLodyAgent)
            }
        )

        let directModes = activeEngine.defaultModes
        let directModeBinding = Binding<String>(
            get: {
                let preferred = coordinator.preferredMode(for: activeEngine)
                if directModes.contains(where: { $0.id == preferred }) {
                    return preferred
                }
                return directModes.first?.id ?? activeEngine.defaultSafeModeID
            },
            set: { newValue in
                coordinator.settings.defaultModes[activeEngine] = newValue
            }
        )

        let discoveredWorkspaces = coordinator.lodyCatalog?.workspaces ?? []
        let lodyWorkspaceBinding = Binding<String>(
            get: {
                if useCustomLodyWorkspace {
                    return "__custom__"
                }
                let raw = coordinator.settings.lodyConfig.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty {
                    return ""
                }
                if let matched = discoveredWorkspaces.first(where: { $0.id == raw || $0.slug == raw || $0.name == raw }) {
                    return matched.id
                }
                return "__custom__"
            },
            set: { newValue in
                if newValue == "__custom__" {
                    useCustomLodyWorkspace = true
                } else {
                    useCustomLodyWorkspace = false
                    coordinator.settings.lodyConfig.workspace = newValue
                    Task { await coordinator.refreshLodyCatalog() }
                }
            }
        )

        return Form {
            Section("默认执行与唤起偏好") {
                Picker("默认 AI 引擎", selection: $coordinator.settings.defaultEngine) {
                    ForEach(AgentEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }

                if activeEngine == .lody {
                    Picker("默认 Lody Agent", selection: lodyAgentSelectionBinding) {
                        Text("Workspace 默认 Agent").tag("default")
                        Divider()
                        ForEach(lodyAgents) { agent in
                            Text(agent.models.isEmpty ? agent.name : "\(agent.name)（\(agent.models.count) 个模型）")
                                .tag(agent.id)
                        }
                        Divider()
                        Text("自定义 Agent Config ID...").tag("__custom__")
                    }

                    if useCustomLodyAgentConfig {
                        labeledInputRow(
                            title: "自定义 Agent Config ID",
                            placeholder: "输入 Lody agent-config 名称或 UUID",
                            text: $coordinator.settings.lodyConfig.defaultAgentConfig
                        )
                    }

                    Picker("默认模型", selection: lodyModelBinding) {
                        ForEach(lodyModels) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }

                    if currentLodyAgent.isEmpty || currentLodyAgent == "default" {
                        Text("选择具体的 Lody Agent（如 Antigravity / Claude Code / Codex）后，即可在此展开并选择该 Agent 下的全部模型。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if lodyModels.count <= 1 {
                        Text("当前 Lody Agent 未上报独立模型列表，派发时将自动使用其默认模型。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("默认模型", selection: directModelBinding) {
                        ForEach(directModels) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                }

                Picker("默认思考强度", selection: $coordinator.settings.defaultEffort) {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Text(effort.displayName).tag(effort)
                    }
                }

                if activeEngine == .lody {
                    Picker("默认模式", selection: lodyModeBinding) {
                        ForEach(lodyModes) { modeOpt in
                            Text(modeOpt.displayName).tag(modeOpt.id)
                        }
                    }
                } else {
                    Picker("默认模式", selection: directModeBinding) {
                        ForEach(directModes) { modeOpt in
                            Text(modeOpt.displayName).tag(modeOpt.id)
                        }
                    }
                }

                if activeEngine == .lody {
                    HStack {
                        Text("唤起方式")
                        Spacer()
                        Text("Lody 工作区持久化会话 · Markdown")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("默认唤起方式", selection: $coordinator.settings.defaultLaunchMode) {
                        ForEach(ExecutionLaunchMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
            }

            if activeEngine == .lody {
                Section("Lody.ai 工作区编排设置") {
                    if !discoveredWorkspaces.isEmpty {
                        Picker("目标 Workspace", selection: lodyWorkspaceBinding) {
                            Text("自动使用当前默认工作区").tag("")
                            Divider()
                            ForEach(discoveredWorkspaces) { ws in
                                Text(ws.displayLabel).tag(ws.id)
                            }
                            Divider()
                            Text("手动输入 Workspace...").tag("__custom__")
                        }
                        if useCustomLodyWorkspace {
                            labeledInputRow(
                                title: "自定义 Workspace",
                                placeholder: "输入 Workspace 名称、Slug 或 ID",
                                text: $coordinator.settings.lodyConfig.workspace
                            )
                        }
                    } else {
                        labeledInputRow(
                            title: "Workspace 名称 / ID",
                            placeholder: "留空自动使用当前默认工作区",
                            text: $coordinator.settings.lodyConfig.workspace
                        )
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            if coordinator.isRefreshingLodyCatalog {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("正在从 Lody 工作区同步 Agent 与模型目录...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if let catalog = coordinator.lodyCatalog, !catalog.agentConfigs.isEmpty {
                                Text("已从 Lody 同步 \(catalog.agentConfigs.count) 个 Agent · \(catalog.totalModelCount) 个真实模型")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("尚未同步 Lody 目录（当前展示内置回退列表，点右侧即可实时拉取）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(coordinator.isRefreshingLodyCatalog ? "同步中..." : "刷新 Lody 目录") {
                            Task { await coordinator.refreshLodyCatalog() }
                        }
                        .controlSize(.small)
                        .disabled(coordinator.isRefreshingLodyCatalog)
                    }
                }
            }

            Section {
                ForEach(AgentEngine.allCases) { engine in
                    let probe = coordinator.environment?.engines[engine]
                    let modelSummary: String = {
                        if engine == .lody {
                            if let catalog = coordinator.lodyCatalog, !catalog.agentConfigs.isEmpty {
                                return "\(catalog.agentConfigs.count) Agent · \(catalog.totalModelCount) 模型"
                            }
                            return "\(coordinator.lodyAgentConfigOptions.count) 个内置 Agent"
                        }
                        let count = coordinator.availableModelsByEngine[engine]?.count ?? engine.defaultModels.count
                        return "\(count) 个模型"
                    }()
                    HStack(spacing: 10) {
                        Circle()
                            .fill(probe?.isInstalled == true ? CDTheme.statusGreen : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.displayName)
                                .font(.subheadline.weight(.medium))
                            Text(probe?.executablePath ?? probe?.errorMessage ?? "检测中...")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(probe?.version ?? (probe?.isInstalled == false ? "未安装" : "..."))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(modelSummary)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if let env = coordinator.environment {
                    toolRow(title: "Git", probe: env.git)
                    toolRow(title: "GitHub CLI (gh)", probe: env.gh)
                }
            } header: {
                HStack {
                    Text("本机 CLI 实时探测")
                    Spacer()
                    Button(coordinator.isDetectingEnvironment ? "检测中..." : "重新检测") {
                        Task { await coordinator.refreshEnvironment() }
                    }
                    .controlSize(.small)
                    .disabled(coordinator.isDetectingEnvironment)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func toolRow(title: String, probe: CLIProbeStatus) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(probe.isInstalled ? CDTheme.statusGreen : CDTheme.statusAmber)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(probe.executablePath ?? probe.errorMessage ?? "未找到")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(probe.version ?? "未安装")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - 4. 工作区

    private var workspacesTab: some View {
        let mappings = coordinator.knownRepositoryMappings

        return Form {
            Section("默认审查方式与代码搜索目录") {
                Toggle("默认使用独立 Git Worktree 隔离审查（推荐，不碰当前开发分支）", isOn: $coordinator.settings.lodyConfig.useLodyWorktree)
                Text("默认开：在独立 Worktree 签出 PR 分支审查（Lody 会话仍归属在对应项目下）；单次确认卡片里也可随时临时切为「直用主目录」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("代码搜索根目录")
                    Spacer(minLength: 12)
                    TextField(
                        "",
                        text: Binding(
                            get: { coordinator.settings.workspaceSearchRoots.joined(separator: ", ") },
                            set: { raw in
                                coordinator.settings.workspaceSearchRoots = raw
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }
                            }
                        ),
                        prompt: Text("~/work, ~/projects（逗号分隔）")
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)

                    Button("添加目录...") {
                        if let chosen = pickFolderPanel(title: "选择要扫描的代码根目录") {
                            let tildePath = abbreviateTilde(chosen)
                            if !coordinator.settings.workspaceSearchRoots.contains(tildePath)
                                && !coordinator.settings.workspaceSearchRoots.contains(chosen) {
                                coordinator.settings.workspaceSearchRoots.append(tildePath)
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }

            Section {
                if mappings.isEmpty {
                    Text("暂未发现本地 Git 仓库。可添加代码根目录，或点下方直接为某个 owner/repo 指定本地目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mappings) { row in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(row.repository)
                                        .font(.subheadline.weight(.medium))
                                    if row.isOverridden {
                                        Text("已固定")
                                            .font(.caption2)
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    } else if let first = row.candidates.first {
                                        Text(first.sourceLabel)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.12), in: Capsule())
                                    }
                                }
                                Text(row.resolvedPath ?? "未绑定（将自动浅克隆）")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 8)

                            if row.candidates.count > 1 {
                                Menu {
                                    ForEach(row.candidates) { cand in
                                        Button {
                                            coordinator.setRepositoryDirectoryOverride(repository: row.repository, path: cand.path)
                                        } label: {
                                            if row.resolvedPath == cand.path {
                                                Label("\(cand.displayName) (\(abbreviateTilde(cand.path)))", systemImage: "checkmark")
                                            } else {
                                                Text("\(cand.displayName) (\(abbreviateTilde(cand.path)))")
                                            }
                                        }
                                    }
                                } label: {
                                    Text("切换副本")
                                }
                                .controlSize(.small)
                                .fixedSize()
                            }

                            Button("选目录...") {
                                if let chosen = pickFolderPanel(title: "为 \(row.repository) 指定本地目录", initialPath: row.resolvedPath) {
                                    coordinator.setRepositoryDirectoryOverride(repository: row.repository, path: chosen)
                                }
                            }
                            .controlSize(.small)

                            if row.isOverridden {
                                Button("重置") {
                                    coordinator.setRepositoryDirectoryOverride(repository: row.repository, path: nil)
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                HStack(spacing: 8) {
                    Text("手动绑定仓库")
                    Spacer(minLength: 12)
                    TextField("", text: $newRepoKeyInput, prompt: Text("如 acme/web"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button("选目录绑定...") {
                        let repo = newRepoKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !repo.isEmpty else { return }
                        if let chosen = pickFolderPanel(title: "为 \(repo) 选择本地目录") {
                            coordinator.setRepositoryDirectoryOverride(repository: repo, path: chosen)
                            newRepoKeyInput = ""
                        }
                    }
                    .controlSize(.small)
                    .disabled(newRepoKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                HStack {
                    Text("仓库 → 本地目录映射（全引擎共用，支持自动发现与手动指定）")
                    Spacer()
                    Button("重新扫描") {
                        coordinator.refreshDiscoveredLocalRepos()
                    }
                    .controlSize(.small)
                }
            }

            Section("系统集成与轮询") {
                Stepper(
                    "同步间隔：\(coordinator.settings.pollIntervalSeconds) 秒",
                    value: $coordinator.settings.pollIntervalSeconds,
                    in: 60...600,
                    step: 30
                )
                Toggle("开机自动启动", isOn: $coordinator.settings.launchAtLogin)
                Toggle("有新协作请求或草稿就绪时发送 macOS 原生通知", isOn: $coordinator.settings.notificationsEnabled)
            }

            if coordinator.settings.developerModeEnabled {
                Section("开发者模式") {
                    Toggle(
                        "启用开发者模式（关闭将自动清理演示数据）",
                        isOn: Binding(
                            get: { coordinator.settings.developerModeEnabled },
                            set: { coordinator.setDeveloperMode($0) }
                        )
                    )

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("收件箱演示任务")
                            Text("向收件箱注入示例 PR 与多平台消息，仅驻留内存。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if coordinator.hasDemoItems {
                            Button("清除演示任务") {
                                coordinator.clearDemoItems()
                            }
                            .controlSize(.small)
                        } else {
                            Button("加载演示任务") {
                                coordinator.loadDemoItems()
                            }
                            .controlSize(.small)
                        }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("用量统计示例数据")
                            Text("向统计页注入跨 5 天 / 四引擎示例数据预览图表，绝不写入本地 SQLite 账本。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if coordinator.hasDemoUsageRuns {
                            Button("清除示例统计") {
                                coordinator.clearDemoUsageRuns()
                            }
                            .controlSize(.small)
                        } else {
                            Button("加载示例统计") {
                                coordinator.loadDemoUsageRuns()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("CollabDock")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let toast = devModeToast {
                        Text(toast)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(appVersionLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    handleVersionTap()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func handleVersionTap() {
        let now = Date()
        if now.timeIntervalSince(lastVersionTapAt) > 2.0 {
            versionTapCount = 0
        }
        lastVersionTapAt = now
        versionTapCount += 1

        if versionTapCount >= 5 {
            versionTapCount = 0
            toggleDeveloperModeWithFeedback()
        } else if versionTapCount >= 3 {
            let remaining = 5 - versionTapCount
            let actionLabel = coordinator.settings.developerModeEnabled ? "关闭" : "开启"
            devModeToast = "再点 \(remaining) 次\(actionLabel)开发者模式"
        }
    }

    private func toggleDeveloperModeWithFeedback() {
        let next = !coordinator.settings.developerModeEnabled
        coordinator.setDeveloperMode(next)
        devModeToast = next ? "已开启开发者模式" : "已关闭开发者模式"
        let currentToast = devModeToast
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if devModeToast == currentToast {
                devModeToast = nil
            }
        }
    }

    private func pickFolderPanel(title: String, initialPath: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let initialPath, !initialPath.isEmpty {
            let expanded = (initialPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func abbreviateTilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - 5. 提示词与团队

    private var teamAndGeneralTab: some View {
        Form {
            Section("唤起提示词注入策略") {
                Toggle("唤起 AI 时自动注入选中的任务模板与只读防注入边界", isOn: $coordinator.settings.injectPresetPrompt)
                Text(
                    coordinator.settings.injectPresetPrompt
                    ? "已开启：每次唤起仅注入当前选中的 1 条模板（不会全量注入）+ 只读安全边界；Lody / 后台会话输出人类可读 Markdown，托管草稿模式附加 JSON Schema。确认卡片点「预览提示词」可实时查看完整原文。"
                    : "已关闭：不注入任何模板，仅发送最精简的 PR / 触发上下文与你的补充指令（仍保留 <untrusted_external_data> 隔离）。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                ForEach($coordinator.settings.presets) { $preset in
                    let presetID = preset.id
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("模板名称", text: $preset.name)
                                .textFieldStyle(.roundedBorder)
                            TextEditor(text: $preset.promptInstructions)
                                .font(.system(size: 11.5))
                                .frame(minHeight: 68)
                                .padding(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.7)
                                )
                            if coordinator.settings.presets.count > 1 {
                                HStack {
                                    Spacer()
                                    Button("删除此模板", role: .destructive) {
                                        coordinator.settings.presets.removeAll { $0.id == presetID }
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name).font(.subheadline.weight(.medium))
                            Text(preset.promptInstructions)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("任务模板（仅注入当前选中的 1 条，按个人习惯自由增删）")
                    Spacer()
                    Button("+ 新建模板") {
                        let newPreset = TaskPreset(
                            id: "custom-\(Int(Date().timeIntervalSince1970))",
                            name: "自定义模板",
                            category: .codeReview,
                            promptInstructions: "请帮我 review 这个 PR，重点关注..."
                        )
                        coordinator.settings.presets.append(newPreset)
                    }
                    .controlSize(.small)
                    Button("恢复默认") {
                        coordinator.settings.presets = TaskPreset.defaults
                    }
                    .controlSize(.small)
                }
            }

            Section("团队配置包分发") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("导出 / 导入团队共享配置（作用域、关键词与任务模板）")
                            .font(.subheadline)
                        Text("同事导入时不会覆盖其个人账号、本地路径或默认模型偏好。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(copiedHint == "team-json" ? "已复制" : "复制 JSON") {
                        if let json = coordinator.exportTeamPresetJSON(teamName: "Team") {
                            copyToPasteboard(json, tag: "team-json")
                        }
                    }
                    .controlSize(.small)

                    Button("从剪贴板导入") {
                        if let raw = NSPasteboard.general.string(forType: .string) {
                            switch coordinator.importTeamPresetJSON(raw) {
                            case .success(let msg):
                                copiedHint = msg
                            case .failure(let err):
                                copiedHint = "导入失败：\(err.localizedDescription)"
                            }
                        }
                    }
                    .controlSize(.small)
                }

                if let notice = copiedHint, notice != "team-json", notice != "gh-refresh" {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(notice.hasPrefix("导入失败") ? CDTheme.diffDeletion : CDTheme.statusGreen)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func labeledInputRow(title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            TextField("", text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
        }
    }

    private func copyToPasteboard(_ text: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedHint = tag
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedHint == tag {
                copiedHint = nil
            }
        }
    }
}
