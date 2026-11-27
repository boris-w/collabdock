import AppKit
import SwiftUI
import CollabDockCore

public struct SettingsView: View {
    public enum SettingsTab: Hashable {
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
    @State private var copiedHintIsError: Bool = false
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

    public init(coordinator: AppCoordinator, initialTab: SettingsTab = .connectors) {
        self.coordinator = coordinator
        self._selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            connectorsTab
                .tabItem { Label(L("Sources"), systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(SettingsTab.connectors)
            triggerRulesTab
                .tabItem { Label(L("Rules"), systemImage: "line.3.horizontal.decrease.circle") }
                .tag(SettingsTab.triggerRules)
            enginesTab
                .tabItem { Label(L("AI Engines"), systemImage: "cpu") }
                .tag(SettingsTab.engines)
            workspacesTab
                .tabItem { Label(L("Workspace"), systemImage: "folder") }
                .tag(SettingsTab.workspaces)
            teamAndGeneralTab
                .tabItem { Label(L("Prompts & Team"), systemImage: "text.badge.star") }
                .tag(SettingsTab.teamAndGeneral)
            UsageStatsSettingsView(coordinator: coordinator)
                .tabItem { Label(L("Usage"), systemImage: "chart.bar.xaxis") }
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
            Section(L("GitHub Authentication Status")) {
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
                                Text(auth.hasNotificationsScope ? L("notifications scope enabled (304 zero-quota fast path active)") : L("Token lacks notifications scope; falling back to Search API every 180s"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let rl = coordinator.latestRateLimit {
                                    Text(
                                        coordinator.lastSyncWas304
                                            ? L("API quota remaining: %1$lld / %2$lld · Last 304 zero-cost", rl.remaining, rl.limit)
                                            : L("API quota remaining: %1$lld / %2$lld", rl.remaining, rl.limit)
                                    )
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            } else {
                                Text(auth.errorMessage ?? L("Not signed in to GitHub"))
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                        Spacer()
                        Button(L("Sync Now")) {
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
                            Button(copiedHint == "gh-refresh" ? L("Copied") : L("Copy Upgrade Command")) {
                                copyToPasteboard("gh auth refresh -s notifications", tag: "gh-refresh")
                            }
                            .controlSize(.small)
                        }
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(L("Checking local GitHub authentication status..."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(L("Pluggable Collaboration Connectors")) {
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
                                Text(L("Planned"))
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
                                Text(L("Account Handle"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                TextField(
                                    "",
                                    text: $connector.accountHandle,
                                    prompt: Text(L("Leave empty to detect from gh auth"))
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
            Section(L("Global Trigger Sources")) {
                Toggle(L("@mention in comments / messages (mention)"), isOn: $coordinator.settings.globalTriggerRules.enableMention)
                Toggle(L("Code review requested (review_requested)"), isOn: $coordinator.settings.globalTriggerRules.enableReviewRequested)
                Toggle(L("Task / ticket assigned to me (assigned)"), isOn: $coordinator.settings.globalTriggerRules.enableAssigned)
                Toggle(L("Team assignment / Team Mention"), isOn: $coordinator.settings.globalTriggerRules.enableTeamMention)
            }

            Section(L("@mention Keywords & Hints")) {
                Toggle(L("Require trigger keywords (avoid casual chatter)"), isOn: $coordinator.settings.globalTriggerRules.requireMentionKeywords)
                labeledInputRow(
                    title: L("Trigger Keywords"),
                    placeholder: L("e.g. review, cr, check"),
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

                Toggle(L("Parse --model / --focus hints from comments (pre-fills only, never skips confirmation)"), isOn: $coordinator.settings.globalTriggerRules.parseTriggerHints)
            }

            Section(L("Auto-Archive Rules")) {
                Toggle(L("Auto-archive PRs to Done when approved, merged, or closed on GitHub"), isOn: $coordinator.settings.autoCompleteApprovedOrClosedPRs)
                Text(L("Synced via a single lightweight GraphQL batch request (zero calls when inbox is empty). Only Approved / Merged / Closed PRs are archived; PRs with Request Changes stay in your inbox as Awaiting Fix."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Scope & Noise Filtering")) {
                Toggle(L("Ignore Draft PRs / draft items"), isOn: $coordinator.settings.globalTriggerRules.ignoreDraftItems)
                Toggle(L("Ignore bot accounts"), isOn: $coordinator.settings.globalTriggerRules.ignoreBots)
                labeledInputRow(
                    title: L("Scope Allowlist"),
                    placeholder: L("e.g. org/*, #oncall* (empty allows all)"),
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
                    title: L("Scope Denylist"),
                    placeholder: L("e.g. org/sandbox (overrides allowlist)"),
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
            Section(L("Default Execution Preferences")) {
                Picker(L("Default AI Engine"), selection: $coordinator.settings.defaultEngine) {
                    ForEach(AgentEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }

                if activeEngine == .lody {
                    Picker(L("Default Lody Agent"), selection: lodyAgentSelectionBinding) {
                        Text(L("Workspace Default Agent")).tag("default")
                        Divider()
                        ForEach(lodyAgents) { agent in
                            Text(agent.models.isEmpty ? agent.name : L("%@ (%lld models)", agent.name, agent.models.count))
                                .tag(agent.id)
                        }
                        Divider()
                        Text(L("Custom Agent Config ID...")).tag("__custom__")
                    }

                    if useCustomLodyAgentConfig {
                        labeledInputRow(
                            title: L("Custom Agent Config ID"),
                            placeholder: L("Enter Lody agent-config name or UUID"),
                            text: $coordinator.settings.lodyConfig.defaultAgentConfig
                        )
                    }

                    Picker(L("Default Model"), selection: lodyModelBinding) {
                        ForEach(lodyModels) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }

                    if currentLodyAgent.isEmpty || currentLodyAgent == "default" {
                        Text(L("Select a specific Lody Agent (e.g. Antigravity / Claude Code / Codex) to view and choose from all models it provides."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if lodyModels.count <= 1 {
                        Text(L("This Lody Agent did not report individual models; its default model will be used automatically."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker(L("Default Model"), selection: directModelBinding) {
                        ForEach(directModels) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                }

                Picker(L("Default Reasoning Effort"), selection: $coordinator.settings.defaultEffort) {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Text(effort.displayName).tag(effort)
                    }
                }

                if activeEngine == .lody {
                    Picker(L("Default Mode"), selection: lodyModeBinding) {
                        ForEach(lodyModes) { modeOpt in
                            Text(modeOpt.displayName).tag(modeOpt.id)
                        }
                    }
                } else {
                    Picker(L("Default Mode"), selection: directModeBinding) {
                        ForEach(directModes) { modeOpt in
                            Text(modeOpt.displayName).tag(modeOpt.id)
                        }
                    }
                }

                if activeEngine == .lody {
                    HStack {
                        Text(L("Launch Mode"))
                        Spacer()
                        Text(L("Lody Workspace Session · Markdown"))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker(L("Default Launch Mode"), selection: $coordinator.settings.defaultLaunchMode) {
                        ForEach(ExecutionLaunchMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
            }

            if activeEngine == .lody {
                Section(L("Lody.ai Workspace Orchestration")) {
                    if !discoveredWorkspaces.isEmpty {
                        Picker(L("Target Workspace"), selection: lodyWorkspaceBinding) {
                            Text(L("Use current default workspace automatically")).tag("")
                            Divider()
                            ForEach(discoveredWorkspaces) { ws in
                                Text(ws.displayLabel).tag(ws.id)
                            }
                            Divider()
                            Text(L("Enter Workspace manually...")).tag("__custom__")
                        }
                        if useCustomLodyWorkspace {
                            labeledInputRow(
                                title: L("Custom Workspace"),
                                placeholder: L("Enter Workspace name, slug, or ID"),
                                text: $coordinator.settings.lodyConfig.workspace
                            )
                        }
                    } else {
                        labeledInputRow(
                            title: L("Workspace Name / ID"),
                            placeholder: L("Leave empty to use current default workspace"),
                            text: $coordinator.settings.lodyConfig.workspace
                        )
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            if coordinator.isRefreshingLodyCatalog {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(L("Syncing Agents and model catalog from Lody workspace..."))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if let catalog = coordinator.lodyCatalog, !catalog.agentConfigs.isEmpty {
                                Text(L("Synced %1$lld agents · %2$lld models from Lody", catalog.agentConfigs.count, catalog.totalModelCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(L("Lody catalog not synced yet (showing built-in fallback list; click Refresh to fetch live)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(coordinator.isRefreshingLodyCatalog ? L("Syncing...") : L("Refresh Lody Catalog")) {
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
                                return L("%1$lld agents · %2$lld models", catalog.agentConfigs.count, catalog.totalModelCount)
                            }
                            return L("%lld built-in agents", coordinator.lodyAgentConfigOptions.count)
                        }
                        let count = coordinator.availableModelsByEngine[engine]?.count ?? engine.defaultModels.count
                        return L("%lld models", count)
                    }()
                    HStack(spacing: 10) {
                        Circle()
                            .fill(probe?.isInstalled == true ? CDTheme.statusGreen : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.displayName)
                                .font(.subheadline.weight(.medium))
                            Text(probe?.executablePath ?? probe?.errorMessage ?? L("Detecting..."))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(probe?.version ?? (probe?.isInstalled == false ? L("Not installed") : "..."))
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
                    Text(L("Local CLI Detection"))
                    Spacer()
                    Button(coordinator.isDetectingEnvironment ? L("Detecting...") : L("Re-detect")) {
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
                Text(probe.executablePath ?? probe.errorMessage ?? L("Not found"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(probe.version ?? L("Not installed"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - 4. 工作区

    private var workspacesTab: some View {
        let mappings = coordinator.knownRepositoryMappings

        return Form {
            Section(L("Language")) {
                Picker(L("Interface Language"), selection: $coordinator.settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                if coordinator.needsRestartForLanguageChange {
                    HStack {
                        Text(L("Restart CollabDock to apply the new interface language."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Restart Now")) {
                            coordinator.relaunchApp()
                        }
                        .controlSize(.small)
                    }
                } else {
                    Text(L("Interface language changes take effect after restarting CollabDock."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker(L("Review Language"), selection: $coordinator.settings.reviewLanguage) {
                    ForEach(ReviewLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                Text(L("Language used by CollabDock for GitHub review headings, severity labels, local reports, and multi-model consensus text."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Review Workspace & Search Roots")) {
                Toggle(L("Use isolated Git Worktrees by default (recommended; leaves your current branch untouched)"), isOn: $coordinator.settings.lodyConfig.useLodyWorktree)
                Text(L("On by default: checks out PR branches in an isolated worktree (Lody sessions still stay under the project). You can switch to the main directory on any confirmation card."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(L("Code Search Roots"))
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
                        prompt: Text(L("~/work, ~/projects (comma-separated)"))
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)

                    Button(L("Add Folder...")) {
                        if let chosen = pickFolderPanel(title: L("Select a code root directory to scan")) {
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
                    Text(L("No local Git repositories found yet. Add a search root or bind an owner/repo to a local folder below."))
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
                                        Text(L("Pinned"))
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
                                Text(row.resolvedPath ?? L("Unbound (will auto shallow clone)"))
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
                                    Text(L("Switch Copy"))
                                }
                                .controlSize(.small)
                                .fixedSize()
                            }

                            Button(L("Choose...")) {
                                if let chosen = pickFolderPanel(title: L("Choose local directory for %@", row.repository), initialPath: row.resolvedPath) {
                                    coordinator.setRepositoryDirectoryOverride(repository: row.repository, path: chosen)
                                }
                            }
                            .controlSize(.small)

                            if row.isOverridden {
                                Button(L("Reset")) {
                                    coordinator.setRepositoryDirectoryOverride(repository: row.repository, path: nil)
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                HStack(spacing: 8) {
                    Text(L("Bind Repository"))
                    Spacer(minLength: 12)
                    TextField("", text: $newRepoKeyInput, prompt: Text(L("e.g. acme/web")))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Button(L("Bind Folder...")) {
                        let repo = newRepoKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !repo.isEmpty else { return }
                        if let chosen = pickFolderPanel(title: L("Choose local directory for %@", repo)) {
                            coordinator.setRepositoryDirectoryOverride(repository: repo, path: chosen)
                            newRepoKeyInput = ""
                        }
                    }
                    .controlSize(.small)
                    .disabled(newRepoKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                HStack {
                    Text(L("Repository → Local Directory Mapping (shared across all engines)"))
                    Spacer()
                    Button(L("Rescan")) {
                        coordinator.refreshDiscoveredLocalRepos()
                    }
                    .controlSize(.small)
                }
            }

            Section(L("System & Polling")) {
                Stepper(
                    L("Sync interval: %llds", coordinator.settings.pollIntervalSeconds),
                    value: $coordinator.settings.pollIntervalSeconds,
                    in: 60...600,
                    step: 30
                )
                Toggle(L("Launch at login"), isOn: $coordinator.settings.launchAtLogin)
                Toggle(L("Send macOS notifications for new requests or ready drafts"), isOn: $coordinator.settings.notificationsEnabled)
            }

            if coordinator.settings.developerModeEnabled {
                Section(L("Developer Mode")) {
                    Toggle(
                        L("Enable Developer Mode (disabling clears sample data)"),
                        isOn: Binding(
                            get: { coordinator.settings.developerModeEnabled },
                            set: { coordinator.setDeveloperMode($0) }
                        )
                    )

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Inbox Sample Tasks"))
                            Text(L("Inject sample PRs and multi-platform items into the inbox (in-memory only)."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if coordinator.hasDemoItems {
                            Button(L("Clear Sample Tasks")) {
                                coordinator.clearDemoItems()
                            }
                            .controlSize(.small)
                        } else {
                            Button(L("Load Sample Tasks")) {
                                coordinator.loadDemoItems()
                            }
                            .controlSize(.small)
                        }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Usage Sample Data"))
                            Text(L("Inject 5-day / 4-engine sample usage stats to preview charts (never written to SQLite)."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if coordinator.hasDemoUsageRuns {
                            Button(L("Clear Sample Stats")) {
                                coordinator.clearDemoUsageRuns()
                            }
                            .controlSize(.small)
                        } else {
                            Button(L("Load Sample Stats")) {
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
            devModeToast = coordinator.settings.developerModeEnabled
                ? L("Tap %lld more times to disable Developer Mode", remaining)
                : L("Tap %lld more times to enable Developer Mode", remaining)
        }
    }

    private func toggleDeveloperModeWithFeedback() {
        let next = !coordinator.settings.developerModeEnabled
        coordinator.setDeveloperMode(next)
        devModeToast = next ? L("Developer Mode enabled") : L("Developer Mode disabled")
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
            Section(L("Prompt Injection Strategy")) {
                Toggle(L("Inject the selected prompt preset and read-only safety guardrails"), isOn: $coordinator.settings.injectPresetPrompt)
                Text(
                    coordinator.settings.injectPresetPrompt
                    ? L("Enabled: injects only the single selected preset plus read-only guardrails. Lody / background sessions output Markdown; managed drafts include a JSON Schema. Click \"Prompt\" on the confirmation card to inspect the full text.")
                    : L("Disabled: no preset is injected; only the minimal PR / trigger context and your extra note are sent (with <untrusted_external_data> isolation preserved).")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                ForEach($coordinator.settings.presets) { $preset in
                    let presetID = preset.id
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(L("Preset Name"), text: $preset.name)
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
                                    Button(L("Delete Preset"), role: .destructive) {
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
                    Text(L("Prompt Presets (only the selected preset is injected)"))
                    Spacer()
                    Button(L("+ New Preset")) {
                        let newPreset = TaskPreset(
                            id: "custom-\(Int(Date().timeIntervalSince1970))",
                            name: L("Custom Preset"),
                            category: .codeReview,
                            promptInstructions: L("Please review this PR, focusing on...")
                        )
                        coordinator.settings.presets.append(newPreset)
                    }
                    .controlSize(.small)
                    Button(L("Reset Defaults")) {
                        coordinator.settings.presets = TaskPreset.defaults
                    }
                    .controlSize(.small)
                }
            }

            Section(L("Team Config Bundle")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Export / import shared team config (scopes, keywords, and prompt presets)"))
                            .font(.subheadline)
                        Text(L("Importing never overwrites personal accounts, local paths, or model preferences."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(copiedHint == "team-json" ? L("Copied") : L("Copy JSON")) {
                        if let json = coordinator.exportTeamPresetJSON(teamName: "Team") {
                            copyToPasteboard(json, tag: "team-json")
                        }
                    }
                    .controlSize(.small)

                    Button(L("Import from Clipboard")) {
                        if let raw = NSPasteboard.general.string(forType: .string) {
                            switch coordinator.importTeamPresetJSON(raw) {
                            case .success(let msg):
                                copiedHintIsError = false
                                copiedHint = msg
                            case .failure(let err):
                                copiedHintIsError = true
                                copiedHint = L("Import failed: %@", err.localizedDescription)
                            }
                        }
                    }
                    .controlSize(.small)
                }

                if let notice = copiedHint, notice != "team-json", notice != "gh-refresh" {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(copiedHintIsError ? CDTheme.diffDeletion : CDTheme.statusGreen)
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
