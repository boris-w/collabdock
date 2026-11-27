import AppKit
import SwiftUI
import CollabDockCore

/// 二级钻取页面：跨平台通用的本地人工确认与 AI 模型调度画布
struct TaskDetailView: View {
    let item: CollaborationItem
    @Bindable var coordinator: AppCoordinator
    let onBack: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    @State private var plan: ExecutionPlan
    @State private var showExtraInstructions: Bool = false
    @State private var showPromptPreview: Bool = false

    init(item: CollaborationItem, coordinator: AppCoordinator, onBack: @escaping () -> Void) {
        self.item = item
        self.coordinator = coordinator
        self.onBack = onBack
        self._plan = State(initialValue: coordinator.defaultPlan(for: item))
    }

    private var effectiveLodyAgentConfig: String {
        plan.lodyAgentConfig ?? coordinator.settings.lodyConfig.defaultAgentConfig
    }

    private var modelsForEngine: [ModelOption] {
        if plan.engine == .lody {
            return coordinator.modelsForLody(agentConfig: effectiveLodyAgentConfig)
        }
        return coordinator.availableModelsByEngine[plan.engine] ?? plan.engine.defaultModels
    }

    private var selectedModelOption: ModelOption {
        modelsForEngine.first(where: { $0.id == plan.model })
            ?? ModelOption(id: plan.model, displayName: plan.model)
    }

    private var modesForEngine: [AgentModeOption] {
        coordinator.modes(for: plan.engine, lodyAgentConfig: effectiveLodyAgentConfig)
    }

    private var selectedModeOption: AgentModeOption {
        let current = plan.mode ?? coordinator.preferredMode(for: plan.engine, lodyAgentConfig: effectiveLodyAgentConfig)
        return modesForEngine.first(where: { $0.id == current })
            ?? AgentModeOption(id: current, displayName: current == "__agent_default__" ? "跟随 Agent 默认" : current)
    }

    private var availablePresets: [TaskPreset] {
        coordinator.presets(for: item)
    }

    private var selectedPreset: TaskPreset {
        availablePresets.first(where: { $0.id == plan.presetID })
            ?? coordinator.settings.presets.first(where: { $0.id == plan.presetID })
            ?? TaskPreset.defaults[0]
    }

    private var supportedDeliveryModes: [DeliveryMode] {
        ConnectorCatalog.supportedDeliveryModes(for: item)
    }

    private var compactModelLabel: String {
        selectedModelOption.displayName
            .replacingOccurrences(of: " (Latest)", with: "")
            .replacingOccurrences(of: " (Fast)", with: "")
    }

    private var resolvedDirectory: (path: String?, displayName: String, lodyProjectID: String?) {
        coordinator.resolvedDirectoryInfo(
            forRepository: item.payload.linkedRepository,
            override: plan.targetDirectoryOverride
        )
    }

    private var matchingLocalCandidates: [LocalRepoCandidate] {
        coordinator.localRepoCandidates(forRepository: item.payload.linkedRepository)
    }

    private var directorySummaryLabel: String {
        let modeSuffix = plan.useIsolatedWorktree ? "独立 Worktree" : "主目录"
        return "\(resolvedDirectory.displayName) · \(modeSuffix)"
    }

    private var actionVerb: String {
        switch item.payload {
        case .codeChange: return "审查"
        case .issueTicket: return "排查"
        case .conversation: return "分析"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            detailNavBar
            CDHairlineDivider(leadingInset: 0)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    contextBlock
                    engineTileRow
                    parametersCard
                    extraInstructionsSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)

            CDHairlineDivider(leadingInset: 0)
            bottomActionBar
        }
        .frame(width: CDTheme.popoverWidth, height: CDTheme.detailHeight)
    }

    // MARK: - 顶部返回导航

    private var detailNavBar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("收件箱")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: item.platform.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(item.platform.accentColor)
                Text(item.displayContextTag)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            CDHoverIconButton(
                systemImage: "arrow.up.right.square",
                helpText: "在 \(item.platform.displayName) 中打开"
            ) {
                openURL(item.url)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - 自适应多平台上下文摘要块

    private var contextBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)

            HStack(spacing: 6) {
                platformTriggerBadge
                Text("@\(item.author)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                payloadMetaTrailing
            }

            if let prev = item.previousReview {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CDTheme.statusAmber)
                    let oldShort = prev.reviewedHeadSHA.isEmpty ? "上轮" : String(prev.reviewedHeadSHA.prefix(7))
                    Text("第 \(item.reviewRound) 轮复审 · 上次于 \(oldShort) 用 \(prev.engine.shortName) 审过")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    CDTheme.statusAmber.opacity(scheme == .dark ? 0.12 : 0.10),
                    in: RoundedRectangle(cornerRadius: CDTheme.innerCornerRadius, style: .continuous)
                )
            }

            if let body = item.triggerBody, !body.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(item.platform.accentColor.opacity(0.75))
                        .frame(width: 2.5)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(body)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                        if item.suggestedModel != nil || item.suggestedPresetID != nil {
                            Label("已按触发内容预填建议选项，确认前可随时更改", systemImage: "sparkles")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    CDTheme.subtleSurface(for: scheme),
                    in: RoundedRectangle(cornerRadius: CDTheme.innerCornerRadius, style: .continuous)
                )
            }
        }
    }

    private var platformTriggerBadge: some View {
        let tint = item.triggerKind == .reviewRequested ? CDTheme.statusAmber : item.platform.accentColor
        return Text("\(item.platform.displayName) · \(item.triggerKind.badgeText)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.13), in: Capsule())
    }

    @ViewBuilder
    private var payloadMetaTrailing: some View {
        switch item.payload {
        case .codeChange(let code):
            Text("·")
                .foregroundStyle(.quaternary)
            Text("\(code.changedFiles) files")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                Text("+\(code.additions)")
                    .foregroundStyle(CDTheme.diffAddition)
                Text("-\(code.deletions)")
                    .foregroundStyle(CDTheme.diffDeletion)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .monospacedDigit()

        case .issueTicket(let ticket):
            Spacer()
            if let repo = ticket.linkedRepository {
                Label(repo, systemImage: "folder")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        case .conversation(let conv):
            Spacer()
            if let repo = conv.linkedRepository {
                Label(repo, systemImage: "folder")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var ctaButtonTitle: String {
        if let partner = plan.councilPartner {
            return "双模型会诊 (\(plan.engine.shortName)×\(partner.engine.shortName))"
        }
        if plan.continuityMode == .continueSessionIncremental,
           let prev = item.previousReview,
           prev.engine == plan.engine,
           prev.canContinueSameSession {
            return "续聊原 \(plan.engine.shortName) 会话复审"
        }
        let verb = (item.previousReview != nil) ? "复审" : actionVerb
        if plan.engine == .lody {
            if !plan.model.isEmpty && plan.model != "default" {
                return "Lody · \(compactModelLabel) \(verb)"
            }
            if !effectiveLodyAgentConfig.isEmpty && effectiveLodyAgentConfig != "default" {
                return "Lody · \(coordinator.lodyAgentConfigDisplayName(for: effectiveLodyAgentConfig)) \(verb)"
            }
            return "派发到 Lody \(verb)"
        }
        return "用 \(compactModelLabel) \(verb)"
    }

    // MARK: - 本地 AI 引擎四宫格选择瓷砖

    private var engineTileRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("选择本地 AI 引擎 / 编排端")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(AgentEngine.allCases) { engine in
                    let isSelected = plan.engine == engine
                    Button {
                        withAnimation(.snappy(duration: 0.16)) {
                            plan.engine = engine
                            if engine == .lody {
                                let lodyAgent = plan.lodyAgentConfig ?? coordinator.settings.lodyConfig.defaultAgentConfig
                                plan.lodyAgentConfig = lodyAgent
                                plan.model = coordinator.preferredLodyModel(forAgentConfig: lodyAgent)
                                plan.mode = coordinator.preferredLodyMode(forAgentConfig: lodyAgent)
                                plan.councilPartner = nil
                            } else {
                                plan.lodyAgentConfig = nil
                                let options = coordinator.availableModelsByEngine[engine] ?? engine.defaultModels
                                plan.model = coordinator.settings.defaultModels[engine] ?? options.first?.id ?? ""
                                plan.mode = coordinator.preferredMode(for: engine)
                            }
                            if let prev = item.previousReview {
                                if prev.canContinueSameSession && prev.engine == engine {
                                    plan.continuityMode = .continueSessionIncremental
                                } else if plan.continuityMode == .continueSessionIncremental {
                                    plan.continuityMode = .freshSessionIncremental
                                }
                            }
                            plan.launchMode = AgentDriverCatalog.defaultLaunchMode(
                                for: engine,
                                fallback: coordinator.settings.defaultLaunchMode
                            )
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: engine.symbolName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(isSelected ? engine.brandAccent : .secondary)
                                .frame(width: 24, height: 24)
                                .background(
                                    (isSelected ? engine.brandAccent.opacity(0.14) : CDTheme.subtleSurface(for: scheme)),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )

                            Text(engine.shortName)
                                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8.5)
                        .background(
                            isSelected
                                ? CDTheme.selectedTileFill(for: scheme)
                                : CDTheme.cardBackground(for: scheme),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isSelected
                                        ? CDTheme.selectedTileBorder(for: scheme)
                                        : CDTheme.hairlineBorder(for: scheme),
                                    lineWidth: isSelected ? 1 : 0.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 单张 Grouped Inset 参数卡

    private var isContinuingExistingLodySession: Bool {
        plan.engine == .lody
            && plan.continuityMode == .continueSessionIncremental
            && item.previousReview?.engine == .lody
            && item.previousReview?.canContinueSameSession == true
    }

    private var parametersCard: some View {
        CDInsetCard {
            VStack(spacing: 0) {
                if let prev = item.previousReview {
                    let canContinue = prev.canContinueSameSession && prev.engine == plan.engine
                    let allowedModes: [ReviewContinuityMode] = canContinue
                        ? [.continueSessionIncremental, .freshSessionIncremental, .freshSessionFull]
                        : [.freshSessionIncremental, .freshSessionFull]
                    inlineMenuRow(label: "复审策略", value: plan.continuityMode.shortLabel) {
                        ForEach(allowedModes) { mode in
                            Button {
                                plan.continuityMode = mode
                            } label: {
                                if plan.continuityMode == mode {
                                    Label(mode.displayName, systemImage: "checkmark")
                                } else {
                                    Text(mode.displayName)
                                }
                            }
                        }
                    }

                    CDHairlineDivider()
                }

                if plan.engine == .lody && !isContinuingExistingLodySession {
                    inlineMenuRow(
                        label: "Lody Agent",
                        value: coordinator.lodyAgentConfigDisplayName(for: effectiveLodyAgentConfig)
                    ) {
                        Button {
                            plan.lodyAgentConfig = "default"
                            plan.model = coordinator.preferredLodyModel(forAgentConfig: "default")
                            plan.mode = coordinator.preferredLodyMode(forAgentConfig: "default")
                        } label: {
                            if effectiveLodyAgentConfig == "default" || effectiveLodyAgentConfig.isEmpty {
                                Label("Workspace 默认 Agent", systemImage: "checkmark")
                            } else {
                                Text("Workspace 默认 Agent")
                            }
                        }
                        Divider()
                        ForEach(coordinator.lodyAgentConfigOptions) { agent in
                            Button {
                                plan.lodyAgentConfig = agent.id
                                plan.model = coordinator.preferredLodyModel(forAgentConfig: agent.id)
                                plan.mode = coordinator.preferredLodyMode(forAgentConfig: agent.id)
                            } label: {
                                let labelText = agent.models.isEmpty ? agent.name : "\(agent.name)（\(agent.models.count) 模型）"
                                if effectiveLodyAgentConfig == agent.id
                                    || effectiveLodyAgentConfig.lowercased() == agent.name.lowercased()
                                    || effectiveLodyAgentConfig.lowercased() == agent.agentType?.lowercased() {
                                    Label(labelText, systemImage: "checkmark")
                                } else {
                                    Text(labelText)
                                }
                            }
                        }
                    }

                    CDHairlineDivider()
                }

                inlineMenuRow(
                    label: "模型",
                    value: selectedModelOption.displayName
                ) {
                    ForEach(modelsForEngine) { option in
                        Button {
                            plan.model = option.id
                        } label: {
                            if option.id == plan.model {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                }

                CDHairlineDivider()

                HStack {
                    Text("强度")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach(ReasoningEffort.allCases) { effort in
                            let selected = plan.effort == effort
                            Button {
                                withAnimation(.snappy(duration: 0.14)) {
                                    plan.effort = effort
                                }
                            } label: {
                                Text(effort.shortLabel)
                                    .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? .primary : .secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        selected ? CDTheme.selectedTileFill(for: scheme) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(selected ? CDTheme.hairlineBorder(for: scheme) : .clear, lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(CDTheme.subtleSurface(for: scheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                CDHairlineDivider()

                inlineMenuRow(
                    label: "模式",
                    value: selectedModeOption.displayName
                ) {
                    ForEach(modesForEngine) { modeOpt in
                        Button {
                            plan.mode = modeOpt.id
                        } label: {
                            if modeOpt.id == selectedModeOption.id {
                                Label(modeOpt.displayName, systemImage: "checkmark")
                            } else {
                                Text(modeOpt.displayName)
                            }
                        }
                    }
                }

                if isContinuingExistingLodySession, let sid = item.previousReview?.sessionID {
                    CDHairlineDivider()
                    HStack {
                        Text("续聊目标")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "cube.transparent")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(AgentEngine.lody.brandAccent)
                            Text("原 Lody 会话 · \(String(sid.prefix(8)))")
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            CDTheme.subtleSurface(for: scheme),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8.5)
                } else {
                    CDHairlineDivider()

                    inlineMenuRow(
                        label: "任务模板",
                        value: coordinator.settings.injectPresetPrompt ? selectedPreset.name : "未启用注入"
                    ) {
                        ForEach(availablePresets) { preset in
                            Button {
                                plan.presetID = preset.id
                            } label: {
                                if preset.id == plan.presetID {
                                    Label(preset.name, systemImage: "checkmark")
                                } else {
                                    Text(preset.name)
                                }
                            }
                        }
                    }

                    CDHairlineDivider()

                    if item.payload.linkedRepository != nil {
                        inlineMenuRow(label: "项目目录", value: directorySummaryLabel) {
                            Button {
                                plan.useIsolatedWorktree = true
                            } label: {
                                if plan.useIsolatedWorktree {
                                    Label("独立 Git Worktree（默认，不碰当前分支）", systemImage: "checkmark")
                                } else {
                                    Text("独立 Git Worktree（默认，不碰当前分支）")
                                }
                            }
                            Button {
                                plan.useIsolatedWorktree = false
                            } label: {
                                if !plan.useIsolatedWorktree {
                                    Label("直接在项目主目录中审查", systemImage: "checkmark")
                                } else {
                                    Text("直接在项目主目录中审查")
                                }
                            }

                            if !matchingLocalCandidates.isEmpty {
                                Divider()
                                ForEach(matchingLocalCandidates) { cand in
                                    Button {
                                        plan.targetDirectoryOverride = cand.path
                                    } label: {
                                        let isCurrent = resolvedDirectory.path == cand.path
                                        if isCurrent {
                                            Label("\(cand.displayName)（\(cand.sourceLabel)）", systemImage: "checkmark")
                                        } else {
                                            Text("\(cand.displayName)（\(cand.sourceLabel)）")
                                        }
                                    }
                                }
                            }

                            Divider()
                            Button("选择其他本地目录...") {
                                let panel = NSOpenPanel()
                                panel.title = "选择本次审查使用的本地项目目录"
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.allowsMultipleSelection = false
                                if let cur = resolvedDirectory.path {
                                    panel.directoryURL = URL(fileURLWithPath: cur, isDirectory: true)
                                }
                                if panel.runModal() == .OK, let url = panel.url {
                                    plan.targetDirectoryOverride = url.path
                                }
                            }
                        }

                        CDHairlineDivider()
                    }

                    if plan.engine == .lody {
                        HStack {
                            Text("会话模式")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "cube.transparent")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(AgentEngine.lody.brandAccent)
                                Text("Lody 工作区会话 · Markdown")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                CDTheme.subtleSurface(for: scheme),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8.5)
                    } else {
                        inlineMenuRow(label: "交付方式", value: plan.deliveryMode.shortLabel(for: item.platform)) {
                            ForEach(supportedDeliveryModes) { mode in
                                Button {
                                    plan.deliveryMode = mode
                                } label: {
                                    if mode == plan.deliveryMode {
                                        Label(mode.displayName(for: item.platform), systemImage: "checkmark")
                                    } else {
                                        Text(mode.displayName(for: item.platform))
                                    }
                                }
                            }
                        }

                        CDHairlineDivider()

                        inlineMenuRow(label: "唤起方式", value: plan.launchMode.shortLabel) {
                            ForEach(ExecutionLaunchMode.allCases) { mode in
                                Button {
                                    plan.launchMode = mode
                                } label: {
                                    if mode == plan.launchMode {
                                        Label(mode.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(mode.displayName)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func inlineMenuRow<MenuItems: View>(
        label: String,
        value: String,
        @ViewBuilder menuItems: @escaping () -> MenuItems
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                menuItems()
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    CDTheme.subtleSurface(for: scheme),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8.5)
    }

    private var extraInstructionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Button {
                    withAnimation(.snappy(duration: 0.16)) {
                        showExtraInstructions.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showExtraInstructions ? "chevron.down" : "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text(showExtraInstructions ? "收起补充指令" : "补充指令")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if plan.engine != .lody {
                    Button {
                        withAnimation(.snappy(duration: 0.16)) {
                            if plan.councilPartner == nil {
                                let partnerEngine: AgentEngine = (plan.engine == .claudeCode) ? .codex : .claudeCode
                                let partnerModels = coordinator.availableModelsByEngine[partnerEngine] ?? partnerEngine.defaultModels
                                let partnerModel = coordinator.settings.defaultModels[partnerEngine] ?? partnerModels.first?.id ?? ""
                                plan.councilPartner = CouncilPartner(engine: partnerEngine, model: partnerModel, effort: plan.effort)
                            } else {
                                plan.councilPartner = nil
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: plan.councilPartner == nil ? "person.2" : "person.2.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(plan.councilPartner == nil ? "双模型会诊" : "已开启双模型会诊")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(plan.councilPartner == nil ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    withAnimation(.snappy(duration: 0.16)) {
                        showPromptPreview.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showPromptPreview ? "eye.slash" : "doc.plaintext")
                            .font(.system(size: 10, weight: .semibold))
                        Text(showPromptPreview ? "隐藏提示词" : "预览提示词")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(showPromptPreview ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }

            if let partner = plan.councilPartner {
                let eligibleEngines: [AgentEngine] = [.claudeCode, .codex, .antigravity].filter { $0 != plan.engine }
                let partnerModels = coordinator.availableModelsByEngine[partner.engine] ?? partner.engine.defaultModels
                let partnerModelDisplay = partnerModels.first(where: { $0.id == partner.model })?.displayName ?? partner.model

                CDInsetCard {
                    HStack(spacing: 8) {
                        Text("会诊搭档")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            ForEach(eligibleEngines) { eng in
                                Button(eng.shortName) {
                                    let opts = coordinator.availableModelsByEngine[eng] ?? eng.defaultModels
                                    let modelID = coordinator.settings.defaultModels[eng] ?? opts.first?.id ?? ""
                                    plan.councilPartner = CouncilPartner(engine: eng, model: modelID, effort: partner.effort)
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(partner.engine.shortName)
                                    .font(.system(size: 11.5, weight: .medium))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(CDTheme.subtleSurface(for: scheme), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()

                        Menu {
                            ForEach(partnerModels) { opt in
                                Button(opt.displayName) {
                                    plan.councilPartner?.model = opt.id
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(partnerModelDisplay)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(CDTheme.subtleSurface(for: scheme), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7.5)
                }
            }

            if showExtraInstructions {
                TextField("例如：重点关注 Redis 缓存一致性与事务回滚...", text: $plan.extraInstructions, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .lineLimit(2...4)
                    .padding(9)
                    .background(
                        CDTheme.cardBackground(for: scheme),
                        in: RoundedRectangle(cornerRadius: CDTheme.innerCornerRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CDTheme.innerCornerRadius, style: .continuous)
                            .strokeBorder(CDTheme.hairlineBorder(for: scheme), lineWidth: 0.6)
                    )
            }

            if showPromptPreview {
                let isBgMode = (plan.engine == .lody) || (plan.launchMode == .nativeBackgroundSession && plan.engine == .claudeCode)
                let previewText = AgentCommandBuilder().buildSafePrompt(
                    item: item,
                    preset: selectedPreset,
                    extraInstructions: plan.extraInstructions,
                    launchMode: isBgMode ? .nativeBackgroundSession : .managedStructuredRun,
                    injectPresetPrompt: coordinator.settings.injectPresetPrompt,
                    previousReview: plan.previousReview,
                    continuityMode: plan.continuityMode
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(coordinator.settings.injectPresetPrompt ? "实际唤起提示词（已注入安全约束与模板）" : "实际唤起提示词（精简模式，未注入模板）")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(previewText)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 110)
                    .padding(8)
                    .background(
                        CDTheme.subtleSurface(for: scheme),
                        in: RoundedRectangle(cornerRadius: CDTheme.innerCornerRadius, style: .continuous)
                    )
                }
            }
        }
    }

    private var bottomActionBar: some View {
        HStack(spacing: 8) {
            Button("忽略") {
                coordinator.dismissItem(id: item.id)
                onBack()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            Spacer()

            CDPrimaryActionButton(
                title: ctaButtonTitle,
                systemImage: "play.fill"
            ) {
                coordinator.confirmAndRun(itemID: item.id, plan: plan)
                onBack()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
