import AppKit
import SwiftUI
import CollabDockCore

/// 二级钻取页面：跨平台通用的本地人工确认与 Lody Agent 调度画布
struct TaskDetailView: View {
    let item: CollaborationItem
    @Bindable var coordinator: AppCoordinator
    let onBack: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    @State private var plan: ExecutionPlan
    @State private var showExtraInstructions: Bool = false
    @State private var showPromptPreview: Bool = false

    init(
        item: CollaborationItem,
        coordinator: AppCoordinator,
        initialShowPromptPreview: Bool = false,
        onBack: @escaping () -> Void
    ) {
        self.item = item
        self.coordinator = coordinator
        self.onBack = onBack
        self._plan = State(initialValue: coordinator.defaultPlan(for: item))
        self._showPromptPreview = State(initialValue: initialShowPromptPreview)
    }

    private var effectiveLodyAgentConfig: String {
        plan.lodyAgentConfig ?? coordinator.settings.lodyConfig.defaultAgentConfig
    }

    private var lodyAgents: [LodyAgentConfigOption] {
        coordinator.lodyAgentConfigOptions
    }

    private var modelsForLody: [ModelOption] {
        coordinator.modelsForLody(agentConfig: effectiveLodyAgentConfig)
    }

    private var selectedModelOption: ModelOption {
        modelsForLody.first(where: { $0.id == plan.model })
            ?? ModelOption(id: plan.model, displayName: plan.model)
    }

    private var availablePresets: [TaskPreset] {
        coordinator.presets(for: item)
    }

    private var selectedPreset: TaskPreset {
        availablePresets.first(where: { $0.id == plan.presetID })
            ?? coordinator.settings.presets.first(where: { $0.id == plan.presetID })
            ?? TaskPreset.defaults[0]
    }

    private var compactModelLabel: String {
        selectedModelOption.displayName
            .replacingOccurrences(of: " (Latest)", with: "")
            .replacingOccurrences(of: " (Fast)", with: "")
            .replacingOccurrences(of: " (recommended)", with: "")
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
        let modeSuffix = plan.useIsolatedWorktree ? L("Worktree") : L("Main Dir")
        return "\(resolvedDirectory.displayName) · \(modeSuffix)"
    }

    private var actionVerb: String {
        switch item.payload {
        case .codeChange: return L("Review")
        case .issueTicket: return L("Triage")
        case .conversation: return L("Analyze")
        }
    }

    private var isContinuingExistingLodySession: Bool {
        plan.continuityMode == .continueSessionIncremental
            && item.previousReview?.engine == .lody
            && item.previousReview?.canContinueSameSession == true
    }

    private var useAgentTiles: Bool {
        !lodyAgents.isEmpty && lodyAgents.count <= 4
    }

    private func matchesAgent(_ agent: LodyAgentConfigOption) -> Bool {
        let raw = effectiveLodyAgentConfig.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != "default" else { return false }
        let lowered = raw.lowercased()
        return agent.id == raw
            || agent.name.lowercased() == lowered
            || agent.agentType?.lowercased() == lowered
    }

    private func selectLodyAgent(_ selector: String) {
        withAnimation(.snappy(duration: 0.16)) {
            plan.engine = .lody
            plan.launchMode = .nativeBackgroundSession
            plan.lodyAgentConfig = selector
            plan.model = coordinator.preferredLodyModel(forAgentConfig: selector)
            plan.mode = coordinator.preferredLodyMode(forAgentConfig: selector)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            detailNavBar
            CDHairlineDivider(leadingInset: 0)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    contextBlock
                    if !isContinuingExistingLodySession && useAgentTiles {
                        lodyAgentTileRow
                    }
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
        .frame(width: CDTheme.popoverWidth, height: showPromptPreview ? CDTheme.detailHeight + 104 : CDTheme.detailHeight)
    }

    // MARK: - 顶部返回导航

    private var detailNavBar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(L("Inbox"))
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
                helpText: L("Open in %@", item.platform.displayName)
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
                    let oldShort = prev.reviewedHeadSHA.isEmpty ? L("prior") : String(prev.reviewedHeadSHA.prefix(7))
                    Text(L("Round %1$lld re-review · last at %2$@ via %3$@", item.reviewRound, oldShort, prev.engine.shortName))
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
                            Label(L("Pre-filled from trigger comment — adjust anytime before confirming"), systemImage: "sparkles")
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
        if isContinuingExistingLodySession {
            return L("Continue Lody Session")
        }
        let verb = (item.previousReview != nil) ? L("Re-review") : actionVerb
        if !plan.model.isEmpty && plan.model != "default" {
            return L("%1$@ · Lody (%2$@)", verb, compactModelLabel)
        }
        if !effectiveLodyAgentConfig.isEmpty && effectiveLodyAgentConfig != "default" {
            return L("%1$@ · Lody (%2$@)", verb, coordinator.lodyAgentConfigDisplayName(for: effectiveLodyAgentConfig))
        }
        return L("%@ with Lody", verb)
    }

    // MARK: - Lody Agent 主选择瓷砖

    private var lodyAgentTileRow: some View {
        let isDefaultSelected = effectiveLodyAgentConfig.isEmpty || effectiveLodyAgentConfig == "default"
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Lody Agent"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    selectLodyAgent("default")
                } label: {
                    Text(L("Workspace Default"))
                        .font(.system(size: 10, weight: isDefaultSelected ? .semibold : .medium))
                        .foregroundStyle(isDefaultSelected ? Color.accentColor : .secondary)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(
                            isDefaultSelected
                                ? Color.accentColor.opacity(0.12)
                                : CDTheme.subtleSurface(for: scheme),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                ForEach(lodyAgents) { agent in
                    let isSelected = matchesAgent(agent)
                    let accent = agent.inferredUnderlyingEngine?.brandAccent ?? AgentEngine.lody.brandAccent
                    let symbol = agent.inferredUnderlyingEngine?.symbolName ?? "cube.transparent"
                    Button {
                        selectLodyAgent(agent.id)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: symbol)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(isSelected ? accent : .secondary)
                                .frame(width: 24, height: 24)
                                .background(
                                    (isSelected ? accent.opacity(0.14) : CDTheme.subtleSurface(for: scheme)),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )

                            Text(agent.name)
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

    private var parametersCard: some View {
        CDInsetCard {
            VStack(spacing: 0) {
                if let prev = item.previousReview {
                    let canContinue = prev.canContinueSameSession && prev.engine == .lody
                    let allowedModes: [ReviewContinuityMode] = canContinue
                        ? [.continueSessionIncremental, .freshSessionIncremental, .freshSessionFull]
                        : [.freshSessionIncremental, .freshSessionFull]
                    inlineMenuRow(label: L("Re-review"), value: plan.continuityMode.shortLabel) {
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

                if !isContinuingExistingLodySession && !useAgentTiles {
                    inlineMenuRow(
                        label: L("Lody Agent"),
                        value: coordinator.lodyAgentConfigDisplayName(for: effectiveLodyAgentConfig)
                    ) {
                        Button {
                            selectLodyAgent("default")
                        } label: {
                            if effectiveLodyAgentConfig == "default" || effectiveLodyAgentConfig.isEmpty {
                                Label(L("Workspace Default Agent"), systemImage: "checkmark")
                            } else {
                                Text(L("Workspace Default Agent"))
                            }
                        }
                        Divider()
                        ForEach(lodyAgents) { agent in
                            Button {
                                selectLodyAgent(agent.id)
                            } label: {
                                let labelText = agent.models.isEmpty ? agent.name : L("%@ (%lld models)", agent.name, agent.models.count)
                                if matchesAgent(agent) {
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
                    label: L("Model"),
                    value: selectedModelOption.displayName
                ) {
                    ForEach(modelsForLody) { option in
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
                    Text(L("Effort"))
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

                if isContinuingExistingLodySession, let sid = item.previousReview?.sessionID {
                    CDHairlineDivider()
                    HStack {
                        Text(L("Resume Target"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "cube.transparent")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(AgentEngine.lody.brandAccent)
                            Text(L("Existing Lody · %@", String(sid.prefix(8))))
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
                        label: L("Prompt Preset"),
                        value: selectedPreset.name
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

                    if item.payload.linkedRepository != nil {
                        CDHairlineDivider()

                        inlineMenuRow(label: L("Directory"), value: directorySummaryLabel) {
                            Button {
                                plan.useIsolatedWorktree = true
                            } label: {
                                if plan.useIsolatedWorktree {
                                    Label(L("Isolated Git Worktree (default, keeps your branch untouched)"), systemImage: "checkmark")
                                } else {
                                    Text(L("Isolated Git Worktree (default, keeps your branch untouched)"))
                                }
                            }
                            Button {
                                plan.useIsolatedWorktree = false
                            } label: {
                                if !plan.useIsolatedWorktree {
                                    Label(L("Review directly in main project directory"), systemImage: "checkmark")
                                } else {
                                    Text(L("Review directly in main project directory"))
                                }
                            }

                            if !matchingLocalCandidates.isEmpty {
                                Divider()
                                ForEach(matchingLocalCandidates) { cand in
                                    Button {
                                        plan.targetDirectoryOverride = cand.path
                                    } label: {
                                        let isCurrent = resolvedDirectory.path == cand.path
                                        let candidateLabel = L("%@ (%@)", cand.displayName, cand.sourceLabel)
                                        if isCurrent {
                                            Label(candidateLabel, systemImage: "checkmark")
                                        } else {
                                            Text(candidateLabel)
                                        }
                                    }
                                }
                            }

                            Divider()
                            Button(L("Choose Another Folder...")) {
                                let panel = NSOpenPanel()
                                panel.title = L("Select local project folder for this review")
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
                        Text(showExtraInstructions ? L("Hide Note") : L("Add Note"))
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    withAnimation(.snappy(duration: 0.16)) {
                        showPromptPreview.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showPromptPreview ? "eye.slash" : "doc.plaintext")
                            .font(.system(size: 10, weight: .semibold))
                        Text(showPromptPreview ? L("Hide Prompt") : L("Prompt"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(showPromptPreview ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }

            if showExtraInstructions {
                TextField(L("e.g. Focus on Redis cache consistency and transaction rollback..."), text: $plan.extraInstructions, axis: .vertical)
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
                let previewText = AgentCommandBuilder().buildPrompt(
                    item: item,
                    preset: selectedPreset,
                    extraInstructions: plan.extraInstructions,
                    previousReview: plan.previousReview,
                    continuityMode: plan.continuityMode
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Message to send to Lody"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(previewText)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 76)
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
            Button(L("Dismiss")) {
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
