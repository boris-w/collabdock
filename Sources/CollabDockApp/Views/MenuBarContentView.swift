import SwiftUI
import CollabDockCore

public struct MenuBarContentView: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    @State private var activeDetailItemID: String?
    @State private var showQuickStats: Bool = false
    @State private var showImportPRBar: Bool = false
    private let initialShowPromptPreview: Bool
    @State private var importPRInput: String = ""
    @State private var isImportingPR: Bool = false
    @State private var importPRError: String?

    public init(
        coordinator: AppCoordinator,
        initialDetailItemID: String? = nil,
        initialShowStats: Bool = false,
        initialShowImportBar: Bool = false,
        initialShowPromptPreview: Bool = false
    ) {
        self.coordinator = coordinator
        self._activeDetailItemID = State(initialValue: initialDetailItemID)
        self._showQuickStats = State(initialValue: initialShowStats)
        self._showImportPRBar = State(initialValue: initialShowImportBar)
        self.initialShowPromptPreview = initialShowPromptPreview
    }

    private var activeDetailItem: CollaborationItem? {
        guard let id = activeDetailItemID else { return nil }
        return coordinator.items.first(where: { $0.id == id && $0.status.isInboxActive })
    }

    public var body: some View {
        ZStack {
            if let detailItem = activeDetailItem {
                TaskDetailView(
                    item: detailItem,
                    coordinator: coordinator,
                    initialShowPromptPreview: initialShowPromptPreview
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        activeDetailItemID = nil
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if showQuickStats {
                UsageQuickStatsView(
                    coordinator: coordinator,
                    onBack: {
                        withAnimation(.snappy(duration: 0.2)) {
                            showQuickStats = false
                        }
                    },
                    onOpenFullStats: {
                        coordinator.requestedSettingsTab = .stats
                        openSettingsWindow()
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                inboxRootView
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: CDTheme.popoverWidth)
        .animation(.snappy(duration: 0.2), value: activeDetailItemID != nil || showQuickStats)
        .onChange(of: coordinator.requestedDetailItemID) { _, newID in
            if let newID {
                withAnimation(.snappy(duration: 0.2)) {
                    showQuickStats = false
                    activeDetailItemID = newID
                }
                coordinator.requestedDetailItemID = nil
            }
        }
    }

    // MARK: - 一级协作收件箱

    private var inboxRootView: some View {
        VStack(spacing: 0) {
            topChromeBar
            if showImportPRBar {
                CDHairlineDivider(leadingInset: 0)
                importPRBar
            }
            CDHairlineDivider(leadingInset: 0)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch coordinator.selectedTab {
                    case .inbox:
                        if coordinator.activePlatformsInInbox.count > 1 {
                            platformFilterStrip
                        }
                        inboxContent
                    case .completed:
                        completedContent
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
            .scrollIndicators(.hidden)
            .frame(minHeight: 240, maxHeight: 460)

            CDHairlineDivider(leadingInset: 0)
            footerBar
        }
        .onAppear {
            Task {
                await coordinator.popoverDidOpen()
            }
        }
    }

    private var topChromeBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                tabPill(tab: .inbox, title: L("Inbox"), count: coordinator.inboxItems.count)
                tabPill(tab: .completed, title: L("Done"), count: coordinator.completedItems.count)
            }
            .padding(2.5)
            .background(CDTheme.subtleSurface(for: scheme), in: Capsule())

            Spacer()

            HStack(spacing: 2) {
                CDHoverIconButton(
                    systemImage: "chart.bar",
                    helpText: L("View review token & model usage")
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        showQuickStats = true
                    }
                }
                CDHoverIconButton(
                    systemImage: "plus",
                    helpText: L("Paste a GitHub PR URL to review now"),
                    isActive: showImportPRBar
                ) {
                    withAnimation(.snappy(duration: 0.16)) {
                        showImportPRBar.toggle()
                        importPRError = nil
                    }
                }
                CDHoverIconButton(
                    systemImage: "arrow.clockwise",
                    helpText: L("Sync collaboration sources now")
                ) {
                    coordinator.refreshNow()
                }
                CDHoverIconButton(
                    systemImage: "gearshape",
                    helpText: L("Settings (⌘,)")
                ) {
                    openSettingsWindow()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var importPRBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField(L("Paste PR URL or owner/repo#123"), text: $importPRInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        CDTheme.cardBackground(for: scheme),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(CDTheme.hairlineBorder(for: scheme), lineWidth: 0.6)
                    )
                    .onSubmit {
                        submitImportPR()
                    }

                Button(isImportingPR ? "..." : L("Import")) {
                    submitImportPR()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CDTheme.primaryCTAText(for: scheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(CDTheme.primaryCTAFill(for: scheme), in: Capsule())
                .disabled(isImportingPR || importPRInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let err = importPRError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(CDTheme.diffDeletion)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(CDTheme.subtleSurface(for: scheme))
    }

    private func submitImportPR() {
        let input = importPRInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isImportingPR else { return }
        isImportingPR = true
        importPRError = nil
        Task {
            let result = await coordinator.importPullRequest(reference: input)
            isImportingPR = false
            switch result {
            case .success:
                importPRInput = ""
                showImportPRBar = false
            case .failure(let error):
                importPRError = error.localizedDescription
            }
        }
    }

    private func tabPill(tab: AppCoordinator.PopoverTab, title: String, count: Int) -> some View {
        let isSelected = coordinator.selectedTab == tab
        return Button {
            withAnimation(.snappy(duration: 0.16)) {
                coordinator.selectedTab = tab
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            isSelected ? CDTheme.subtleSurface(for: scheme) : Color.clear,
                            in: Capsule()
                        )
                }
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                isSelected ? CDTheme.selectedTileFill(for: scheme) : .clear,
                in: Capsule()
            )
            .shadow(
                color: (isSelected && scheme == .light) ? Color.black.opacity(0.06) : .clear,
                radius: 2,
                x: 0,
                y: 1
            )
        }
        .buttonStyle(.plain)
    }

    /// 多平台来源过滤胶囊（仅当收件箱同时存在多个平台时显现，保持单平台极简）
    private var platformFilterStrip: some View {
        HStack(spacing: 5) {
            filterChip(title: L("All"), platform: nil)
            ForEach(coordinator.activePlatformsInInbox) { platform in
                filterChip(title: platform.displayName, platform: platform)
            }
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private func filterChip(title: String, platform: PlatformKind?) -> some View {
        let isSelected = coordinator.selectedPlatformFilter == platform
        return Button {
            withAnimation(.snappy(duration: 0.14)) {
                coordinator.selectedPlatformFilter = platform
            }
        } label: {
            HStack(spacing: 4) {
                if let platform {
                    Circle()
                        .fill(platform.accentColor)
                        .frame(width: 5, height: 5)
                }
                Text(title)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                isSelected ? CDTheme.selectedTileFill(for: scheme) : CDTheme.subtleSurface(for: scheme),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? CDTheme.hairlineBorder(for: scheme) : .clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 收件箱内容（邮件式管理：运行中 / 失败待重试 / 待确认 / 待审草稿）

    @ViewBuilder
    private var inboxContent: some View {
        let visibleItems = coordinator.filteredInboxItems
        let runningItems = visibleItems.filter {
            $0.status == .preparing || $0.status == .running || $0.status == .publishing
        }
        let failedItems = visibleItems.filter { $0.status == .failed }
        let pendingItems = visibleItems.filter { $0.status == .pendingConfirmation }
        let draftItems = visibleItems.filter { $0.status == .draftReady }

        if visibleItems.isEmpty {
            emptyStateView(
                icon: "checkmark.seal",
                title: L("Inbox Clear"),
                subtitle: L("When someone @mentions you or requests a PR review,\nit will appear here waiting for confirmation.")
            )
        } else {
            if !runningItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader(L("Running"), count: runningItems.count)
                    ForEach(runningItems) { item in
                        RunningTaskBannerView(
                            item: item,
                            onSelect: item.wasAutoStarted ? {
                                withAnimation(.snappy(duration: 0.2)) {
                                    activeDetailItemID = item.id
                                }
                            } : nil,
                            onCancel: {
                                coordinator.cancelRunningItem(id: item.id)
                            }
                        )
                    }
                }
            }

            if !failedItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader(L("Failed"), count: failedItems.count)
                    ForEach(failedItems) { item in
                        CDInsetCard(padding: 10) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(item.displayContextTag)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(CDTheme.diffDeletion)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if item.wasAutoStarted {
                                        Text(L("Auto-start Failed"))
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundStyle(CDTheme.diffDeletion)
                                            .padding(.horizontal, 5.5)
                                            .padding(.vertical, 1.5)
                                            .background(CDTheme.diffDeletion.opacity(0.13), in: Capsule())
                                            .fixedSize()
                                    }
                                    Spacer()
                                    CDPillButton(title: L("Retry"), systemImage: "arrow.clockwise") {
                                        coordinator.retryFailedItem(id: item.id)
                                    }
                                    CDHoverIconButton(systemImage: "trash", helpText: L("Delete item")) {
                                        withAnimation(.snappy(duration: 0.16)) {
                                            coordinator.deleteItem(id: item.id)
                                        }
                                    }
                                }
                                Text(item.errorMessage ?? L("Execution failed"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }

            if !pendingItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader(L("Pending"), count: pendingItems.count)
                    CDInsetCard {
                        VStack(spacing: 0) {
                            ForEach(Array(pendingItems.enumerated()), id: \.element.id) { index, item in
                                CollaborationRowView(
                                    item: item,
                                    onSelect: {
                                        withAnimation(.snappy(duration: 0.2)) {
                                            activeDetailItemID = item.id
                                        }
                                    },
                                    onMarkCompleted: {
                                        withAnimation(.snappy(duration: 0.18)) {
                                            coordinator.markItemCompleted(id: item.id)
                                        }
                                    },
                                    onDelete: {
                                        withAnimation(.snappy(duration: 0.18)) {
                                            coordinator.deleteItem(id: item.id)
                                        }
                                    }
                                )
                                if index < pendingItems.count - 1 {
                                    CDHairlineDivider(leadingInset: 48)
                                }
                            }
                        }
                    }
                }
            }

            if !draftItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader(L("Dispatched & Reviewed"), count: draftItems.count)
                    ForEach(draftItems) { item in
                        DraftResultCardView(
                            item: item,
                            onSelect: item.wasAutoStarted ? {
                                withAnimation(.snappy(duration: 0.2)) {
                                    activeDetailItemID = item.id
                                }
                            } : nil,
                            onOpenSource: { openURL(item.deliveryURL ?? item.url) },
                            onHandoff: item.sessionHandle?.engine == .lody ? { coordinator.openHandoff(for: item) } : nil,
                            onMarkCompleted: {
                                withAnimation(.snappy(duration: 0.18)) {
                                    coordinator.markItemCompleted(id: item.id)
                                }
                            },
                            onDelete: {
                                withAnimation(.snappy(duration: 0.18)) {
                                    coordinator.deleteItem(id: item.id)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 已完成归档

    @ViewBuilder
    private var completedContent: some View {
        let items = coordinator.completedItems
        if items.isEmpty {
            emptyStateView(
                icon: "tray",
                title: L("No completed items yet"),
                subtitle: L("PRs and tasks you mark as done\nwill be archived here for quick reference.")
            )
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(L("Archived"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(items.count)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button(L("Clear Done")) {
                        withAnimation(.snappy(duration: 0.18)) {
                            coordinator.clearCompletedItems()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(L("Clear completed list (keeps local usage stats)"))
                }
                .padding(.horizontal, 4)

                CDInsetCard {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            CompletedItemRowView(
                                item: item,
                                onOpenSource: { openURL(item.deliveryURL ?? item.url) },
                                onHandoff: item.sessionHandle?.engine == .lody ? { coordinator.openHandoff(for: item) } : nil,
                                onDelete: {
                                    withAnimation(.snappy(duration: 0.16)) {
                                        coordinator.deleteItem(id: item.id)
                                    }
                                }
                            )
                            if index < items.count - 1 {
                                CDHairlineDivider(leadingInset: 36)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 极简底栏

    @ViewBuilder
    private var autoStartStatusBar: some View {
        if coordinator.settings.autoStart.isEnabled {
            let paused = coordinator.settings.autoStart.isPaused
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(paused ? CDTheme.statusAmber : CDTheme.statusGreen)
                        .frame(width: 6, height: 6)
                    Text(paused ? L("Auto-Review: Paused") : L("Auto-Review: Active"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(paused ? L("Resume") : L("Pause")) {
                        withAnimation(.snappy(duration: 0.14)) {
                            coordinator.toggleAutoStartPause()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(paused ? CDTheme.statusGreen : CDTheme.statusAmber)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        (paused ? CDTheme.statusGreen : CDTheme.statusAmber).opacity(0.12),
                        in: Capsule()
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(CDTheme.subtleSurface(for: scheme))
                CDHairlineDivider(leadingInset: 0)
            }
        }
    }

    private var footerBar: some View {
        VStack(spacing: 0) {
            autoStartStatusBar
            HStack(spacing: 8) {
            Button {
                coordinator.togglePause()
            } label: {
                HStack(spacing: 6) {
                    if coordinator.isSyncing {
                        ProgressView()
                            .controlSize(.mini)
                        Text(L("Syncing..."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let err = coordinator.lastSyncError {
                        Circle()
                            .fill(CDTheme.diffDeletion)
                            .frame(width: 6, height: 6)
                        Text(err)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if coordinator.isPaused {
                        Circle()
                            .fill(CDTheme.statusAmber)
                            .frame(width: 6, height: 6)
                        Text(L("Polling paused"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if !coordinator.resolvedGitHubUsername.isEmpty {
                        footerGitHubAvatar
                        HStack(spacing: 4) {
                            if let alias = coordinator.resolvedGitHubDisplayName {
                                Text(alias)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.primary.opacity(0.88))
                                Text("@\(coordinator.resolvedGitHubUsername)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("@\(coordinator.resolvedGitHubUsername)")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                    } else {
                        Circle()
                            .fill(statusDotColor)
                            .frame(width: 6, height: 6)
                        Text(footerStatusText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(coordinator.isPaused ? L("Click to resume auto-polling") : L("Click to pause auto-polling"))

            Spacer()

            if coordinator.settings.developerModeEnabled {
                Button {
                    coordinator.requestedSettingsTab = .workspaces
                    openSettingsWindow()
                } label: {
                    Text("DEV")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CDTheme.statusAmber)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(CDTheme.statusAmber.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(L("Developer mode enabled (click to manage in Settings)"))
            }

            Button(L("Quit")) {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7.5)
        }
    }

    private var footerGitHubAvatar: some View {
        ZStack(alignment: .bottomTrailing) {
            if let img = coordinator.githubAvatarImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(Circle())
                    .overlay(
                        Circle().strokeBorder(CDTheme.hairlineBorder(for: scheme), lineWidth: 0.5)
                    )
            } else {
                Circle()
                    .fill(CDTheme.subtleSurface(for: scheme))
                    .frame(width: 18, height: 18)
                    .overlay(
                        Text(String((coordinator.resolvedGitHubDisplayName ?? coordinator.resolvedGitHubUsername).prefix(1)).uppercased())
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    )
            }
            Circle()
                .fill(statusDotColor)
                .frame(width: 5.5, height: 5.5)
                .overlay(
                    Circle().strokeBorder(scheme == .dark ? Color(white: 0.14) : Color.white, lineWidth: 1)
                )
                .offset(x: 1, y: 1)
        }
    }

    private var statusDotColor: Color {
        if coordinator.lastSyncError != nil {
            return CDTheme.diffDeletion
        }
        if coordinator.isPaused {
            return CDTheme.statusAmber
        }
        return CDTheme.statusGreen
    }

    private var footerStatusText: String {
        if let err = coordinator.lastSyncError {
            return err
        }
        if coordinator.isSyncing {
            return L("Syncing...")
        }
        if coordinator.isPaused {
            return L("Polling paused")
        }
        if !coordinator.resolvedGitHubUsername.isEmpty {
            return "@\(coordinator.resolvedGitHubUsername)"
        }
        let enabledCount = coordinator.settings.connectors.filter { $0.isEnabled }.count
        return L("%lld active sources", enabledCount)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private func statusLabel(_ status: CollaborationTaskStatus) -> String {
        switch status {
        case .draftReady: return L("Draft Ready")
        case .completed: return L("Done")
        case .failed: return L("Failed")
        case .dismissed: return L("Dismissed")
        default: return status.rawValue
        }
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}

// MARK: - 跨平台协作列表行

private struct CollaborationRowView: View {
    let item: CollaborationItem
    let onSelect: () -> Void
    let onMarkCompleted: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    private var badgeTint: Color {
        item.triggerKind == .reviewRequested ? CDTheme.statusAmber : item.platform.accentColor
    }

    private var badgeIcon: String {
        if item.triggerKind == .reviewRequested {
            return "eye"
        }
        switch item.platform {
        case .github, .gitlab:
            return "at"
        default:
            return item.platform.symbolName
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: badgeIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(badgeTint)
                .frame(width: 28, height: 28)
                .background(badgeTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3.5) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if item.previousReview != nil {
                        Text(L("Round %lld", item.reviewRound))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(CDTheme.statusAmber)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(CDTheme.statusAmber.opacity(0.14), in: Capsule())
                            .fixedSize()
                    }
                }

                HStack(spacing: 4) {
                    Text(item.displayContextTag)
                        .font(.system(size: 10.5, design: .monospaced))
                    Text("·")
                    Text("@\(item.author)")
                        .font(.system(size: 10.5))

                    Spacer(minLength: 4)

                    if !isHovering {
                        trailingBadge
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let body = item.triggerBody, !body.isEmpty {
                    Text(L("\"%@\"", body))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineLimit(1)
                        .padding(.top, 0.5)
                }
            }

            if isHovering {
                HStack(spacing: 3) {
                    CDHoverIconButton(systemImage: "checkmark", helpText: L("Mark as Done")) {
                        onMarkCompleted()
                    }
                    CDHoverIconButton(systemImage: "trash", helpText: L("Delete item")) {
                        onDelete()
                    }
                    CDPillButton(title: L("Review"), systemImage: "chevron.right") {
                        onSelect()
                    }
                }
                .transition(.opacity)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9.5)
        .background(isHovering ? CDTheme.cardHoverBackground(for: scheme) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    @ViewBuilder
    private var trailingBadge: some View {
        switch item.payload {
        case .codeChange(let code):
            HStack(spacing: 3) {
                Text("+\(code.additions)")
                    .foregroundStyle(CDTheme.diffAddition)
                Text("-\(code.deletions)")
                    .foregroundStyle(CDTheme.diffDeletion)
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .monospacedDigit()

        case .issueTicket, .conversation:
            Text(item.platform.displayName)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(item.platform.accentColor)
                .padding(.horizontal, 5.5)
                .padding(.vertical, 1.5)
                .background(item.platform.accentColor.opacity(0.11), in: Capsule())
        }
    }
}

private struct RunningTaskBannerView: View {
    let item: CollaborationItem
    let onSelect: (() -> Void)?
    let onCancel: () -> Void

    var body: some View {
        CDInsetCard(padding: 11) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(item.displayContextTag)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.wasAutoStarted {
                        Text(L("⚡ Auto"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(CDTheme.statusAmber)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1.5)
                            .background(CDTheme.statusAmber.opacity(0.14), in: Capsule())
                            .fixedSize()
                    }
                    Spacer()
                    CDHoverIconButton(systemImage: "stop.fill", helpText: L("Stop run"), action: onCancel)
                }
                Text(item.progressMessage ?? L("Dispatching Lody review session..."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect?()
            }
        }
    }
}

private struct DraftResultCardView: View {
    let item: CollaborationItem
    let onSelect: (() -> Void)?
    let onOpenSource: () -> Void
    let onHandoff: (() -> Void)?
    let onMarkCompleted: () -> Void
    let onDelete: () -> Void

    private var badgeSpec: (text: String, color: Color, isRunning: Bool) {
        if item.sessionHandle?.engine == .lody {
            switch item.remoteSessionStatus {
            case .running:
                return (L("Reviewing"), CDTheme.statusAmber, true)
            case .completed:
                if item.gitHubReviewVerdict == "CHANGES_REQUESTED" {
                    return (L("Awaiting Fix"), CDTheme.statusAmber, false)
                }
                return (L("Reviewed"), CDTheme.statusGreen, false)
            case .failed:
                return (L("Error"), CDTheme.diffDeletion, false)
            case nil:
                if item.gitHubReviewVerdict == "CHANGES_REQUESTED" {
                    return (L("Awaiting Fix"), CDTheme.statusAmber, false)
                }
                return (L("Dispatched"), CDTheme.statusGreen, false)
            }
        }
        if item.gitHubReviewVerdict == "CHANGES_REQUESTED" {
            return (L("Awaiting Fix"), CDTheme.statusAmber, false)
        }
        return (L("Draft Ready"), CDTheme.statusGreen, false)
    }

    var body: some View {
        let badge = badgeSpec
        CDInsetCard(padding: 11) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    if badge.isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Circle()
                            .fill(badge.color)
                            .frame(width: 6.5, height: 6.5)
                    }
                    Text(item.displayContextTag)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.wasAutoStarted {
                        Text(L("⚡ Auto"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(CDTheme.statusAmber)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(CDTheme.statusAmber.opacity(0.14), in: Capsule())
                            .fixedSize()
                    }
                    Spacer()
                    Text(badge.text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badge.color.opacity(0.13), in: Capsule())
                        .fixedSize()
                    CDHoverIconButton(systemImage: "checkmark", helpText: L("Mark as Done (Archive)"), action: onMarkCompleted)
                    CDHoverIconButton(systemImage: "trash", helpText: L("Delete item"), action: onDelete)
                }

                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect?()
                    }

                if let output = item.executionOutput {
                    Text(output.summaryText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if case .codeReview(let review) = output {
                        HStack(spacing: 10) {
                            severityPill(count: review.criticalCount, label: L("Critical"), color: CDTheme.diffDeletion)
                            severityPill(count: review.warningCount, label: L("Warning"), color: CDTheme.statusAmber)
                            severityPill(count: review.nitCount, label: L("Nit"), color: .secondary)
                            Spacer()
                        }
                    }

                    HStack(spacing: 6) {
                        Spacer()
                        if let onHandoff {
                            CDPillButton(
                                title: L("Open Lody"),
                                systemImage: "cube.transparent",
                                action: onHandoff
                            )
                        }
                        CDPillButton(title: L("Open PR"), systemImage: "arrow.up.right", action: onOpenSource)
                    }
                    .padding(.top, 1)
                }
            }
        }
    }

    private func severityPill(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color.opacity(count > 0 ? 0.9 : 0.25))
                .frame(width: 5, height: 5)
            Text("\(label) \(count)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(count > 0 ? .primary : .tertiary)
        }
    }
}

/// 邮件式「已完成」归档行（保留回看/接管会话与单条删除，关联 ITER-015）
private struct CompletedItemRowView: View {
    let item: CollaborationItem
    let onOpenSource: () -> Void
    let onHandoff: (() -> Void)?
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    private var statusIcon: (name: String, color: Color) {
        guard item.status == .completed else {
            return ("minus.circle", .secondary.opacity(0.6))
        }
        switch item.completionReason {
        case .prApproved:
            return ("checkmark.seal.fill", CDTheme.statusGreen)
        case .prMerged:
            return ("arrow.triangle.merge", Color.purple.opacity(0.85))
        case .prClosed:
            return ("xmark.circle.fill", .secondary.opacity(0.7))
        case .superseded:
            return ("arrow.clockwise.circle.fill", Color.blue.opacity(0.8))
        case .manual, nil:
            return ("checkmark.circle.fill", CDTheme.statusGreen.opacity(0.85))
        }
    }

    private var statusText: String {
        guard item.status == .completed else { return L("Dismissed") }
        if item.completionReason == .superseded {
            return L("Moved to Round %lld", item.reviewRound + 1)
        }
        return (item.completionReason ?? .manual).displayLabel
    }

    var body: some View {
        let icon = statusIcon
        HStack(spacing: 9) {
            Image(systemName: icon.name)
                .font(.system(size: 13))
                .foregroundStyle(icon.color)

            VStack(alignment: .leading, spacing: 2.5) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.displayContextTag)
                        .font(.system(size: 10, design: .monospaced))
                    Text("·")
                    Text(statusText)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                if isHovering {
                    if let onHandoff {
                        CDHoverIconButton(
                            systemImage: "cube.transparent",
                            helpText: L("Open Lody session"),
                            action: onHandoff
                        )
                    }
                    CDHoverIconButton(systemImage: "arrow.up.right", helpText: L("Open in browser"), action: onOpenSource)
                }
                CDHoverIconButton(systemImage: "trash", helpText: L("Delete entry"), action: onDelete)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8.5)
        .background(isHovering ? CDTheme.cardHoverBackground(for: scheme) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenSource)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}
