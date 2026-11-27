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
    @State private var importPRInput: String = ""
    @State private var isImportingPR: Bool = false
    @State private var importPRError: String?

    public init(
        coordinator: AppCoordinator,
        initialDetailItemID: String? = nil,
        initialShowStats: Bool = false,
        initialShowImportBar: Bool = false
    ) {
        self.coordinator = coordinator
        self._activeDetailItemID = State(initialValue: initialDetailItemID)
        self._showQuickStats = State(initialValue: initialShowStats)
        self._showImportPRBar = State(initialValue: initialShowImportBar)
    }

    private var activeDetailItem: CollaborationItem? {
        guard let id = activeDetailItemID else { return nil }
        return coordinator.items.first(where: { $0.id == id && $0.status == .pendingConfirmation })
    }

    public var body: some View {
        ZStack {
            if let detailItem = activeDetailItem {
                TaskDetailView(
                    item: detailItem,
                    coordinator: coordinator
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
                tabPill(tab: .inbox, title: "收件箱", count: coordinator.inboxItems.count)
                tabPill(tab: .completed, title: "已完成", count: coordinator.completedItems.count)
            }
            .padding(2.5)
            .background(CDTheme.subtleSurface(for: scheme), in: Capsule())

            Spacer()

            HStack(spacing: 2) {
                CDHoverIconButton(
                    systemImage: "chart.bar",
                    helpText: "查看 Review Token 与模型统计"
                ) {
                    withAnimation(.snappy(duration: 0.2)) {
                        showQuickStats = true
                    }
                }
                CDHoverIconButton(
                    systemImage: "plus",
                    helpText: "粘贴 GitHub PR 链接立即审查",
                    isActive: showImportPRBar
                ) {
                    withAnimation(.snappy(duration: 0.16)) {
                        showImportPRBar.toggle()
                        importPRError = nil
                    }
                }
                CDHoverIconButton(
                    systemImage: "arrow.clockwise",
                    helpText: "立即同步协作来源"
                ) {
                    coordinator.refreshNow()
                }
                CDHoverIconButton(
                    systemImage: "gearshape",
                    helpText: "偏好设置 (⌘,)"
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
                TextField("粘贴 PR 链接或 owner/repo#123", text: $importPRInput)
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

                Button(isImportingPR ? "..." : "导入") {
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
            filterChip(title: "全部", platform: nil)
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
                title: "收件箱已清空",
                subtitle: "有人 @你 或指派 PR Review 时，\n会自动汇总到这里等待你处理。"
            )
        } else {
            if !runningItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("正在执行", count: runningItems.count)
                    ForEach(runningItems) { item in
                        RunningTaskBannerView(item: item) {
                            coordinator.cancelRunningItem(id: item.id)
                        }
                    }
                }
            }

            if !failedItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader("执行失败", count: failedItems.count)
                    ForEach(failedItems) { item in
                        CDInsetCard(padding: 10) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(item.displayContextTag)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(CDTheme.diffDeletion)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    CDPillButton(title: "重试", systemImage: "arrow.clockwise") {
                                        coordinator.retryFailedItem(id: item.id)
                                    }
                                    CDHoverIconButton(systemImage: "trash", helpText: "删除此条") {
                                        withAnimation(.snappy(duration: 0.16)) {
                                            coordinator.deleteItem(id: item.id)
                                        }
                                    }
                                }
                                Text(item.errorMessage ?? "执行异常")
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
                    sectionHeader("待你确认", count: pendingItems.count)
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
                    sectionHeader("草稿与已派发", count: draftItems.count)
                    ForEach(draftItems) { item in
                        DraftResultCardView(
                            item: item,
                            onOpenSource: { openURL(item.deliveryURL ?? item.url) },
                            onOpenReport: item.localReportPath != nil ? { coordinator.openLocalReport(for: item) } : nil,
                            onHandoff: item.sessionHandle != nil ? { coordinator.openHandoff(for: item) } : nil,
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
                title: "还没有已完成事项",
                subtitle: "审阅完并标为「完成」的 PR 或任务\n会归档在这里，可随时回看或删除。"
            )
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text("已归档")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(items.count)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("清空已完成") {
                        withAnimation(.snappy(duration: 0.18)) {
                            coordinator.clearCompletedItems()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("清空已完成列表（保留本地用量统计账本）")
                }
                .padding(.horizontal, 4)

                CDInsetCard {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            CompletedItemRowView(
                                item: item,
                                onOpenSource: { openURL(item.deliveryURL ?? item.url) },
                                onOpenReport: item.localReportPath != nil ? { coordinator.openLocalReport(for: item) } : nil,
                                onHandoff: item.sessionHandle != nil ? { coordinator.openHandoff(for: item) } : nil,
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

    private var footerBar: some View {
        HStack(spacing: 8) {
            Button {
                coordinator.togglePause()
            } label: {
                HStack(spacing: 6) {
                    if coordinator.isSyncing {
                        ProgressView()
                            .controlSize(.mini)
                        Text("正在同步...")
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
                        Text("监听已暂停")
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
            .help(coordinator.isPaused ? "点击恢复自动轮询" : "点击暂停自动轮询")

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
                .help("开发者模式已开启（点击前往设置管理）")
            }

            Button("退出") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7.5)
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
            return "正在同步..."
        }
        if coordinator.isPaused {
            return "监听已暂停"
        }
        if !coordinator.resolvedGitHubUsername.isEmpty {
            return "@\(coordinator.resolvedGitHubUsername)"
        }
        let enabledCount = coordinator.settings.connectors.filter { $0.isEnabled }.count
        return "\(enabledCount) 个协作来源在线"
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
        case .draftReady: return "草稿就绪"
        case .completed: return "已完成"
        case .failed: return "执行失败"
        case .dismissed: return "已忽略"
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
                        Text("第\(item.reviewRound)轮复审")
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
                    Text("“\(body)”")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineLimit(1)
                        .padding(.top, 0.5)
                }
            }

            if isHovering {
                HStack(spacing: 3) {
                    CDHoverIconButton(systemImage: "checkmark", helpText: "标为已完成") {
                        onMarkCompleted()
                    }
                    CDHoverIconButton(systemImage: "trash", helpText: "删除此条") {
                        onDelete()
                    }
                    CDPillButton(title: "处理", systemImage: "chevron.right") {
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
    let onCancel: () -> Void

    var body: some View {
        CDInsetCard(padding: 11) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(item.displayContextTag)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    CDHoverIconButton(systemImage: "stop.fill", helpText: "中止本次执行", action: onCancel)
                }
                Text(item.progressMessage ?? "正在分析并生成审查草稿...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct DraftResultCardView: View {
    let item: CollaborationItem
    let onOpenSource: () -> Void
    let onOpenReport: (() -> Void)?
    let onHandoff: (() -> Void)?
    let onMarkCompleted: () -> Void
    let onDelete: () -> Void

    private var badgeSpec: (text: String, color: Color, isRunning: Bool) {
        if item.sessionHandle?.engine == .lody {
            switch item.remoteSessionStatus {
            case .running:
                return ("审查中", CDTheme.statusAmber, true)
            case .completed:
                if item.gitHubReviewVerdict == "CHANGES_REQUESTED" {
                    return ("待修复", CDTheme.statusAmber, false)
                }
                return ("审查完成", CDTheme.statusGreen, false)
            case .failed:
                return ("执行异常", CDTheme.diffDeletion, false)
            case nil:
                if item.gitHubReviewVerdict == "CHANGES_REQUESTED" {
                    return ("待修复", CDTheme.statusAmber, false)
                }
                return ("已派发", CDTheme.statusGreen, false)
            }
        }
        if item.gitHubReviewVerdict == "CHANGES_REQUESTED" {
            return ("待修复", CDTheme.statusAmber, false)
        }
        return ("草稿就绪", CDTheme.statusGreen, false)
    }

    var body: some View {
        let badge = badgeSpec
        CDInsetCard(padding: 11) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
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
                    Spacer()
                    Text(badge.text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badge.color.opacity(0.13), in: Capsule())
                        .fixedSize()
                    CDHoverIconButton(systemImage: "checkmark", helpText: "标为已完成（归档）", action: onMarkCompleted)
                    CDHoverIconButton(systemImage: "trash", helpText: "删除此条", action: onDelete)
                }

                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)

                if let output = item.executionOutput {
                    Text(output.summaryText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if case .codeReview(let review) = output {
                        HStack(spacing: 10) {
                            severityPill(count: review.criticalCount, label: "严重", color: CDTheme.diffDeletion)
                            severityPill(count: review.warningCount, label: "建议", color: CDTheme.statusAmber)
                            severityPill(count: review.nitCount, label: "细节", color: .secondary)
                            Spacer()
                        }
                    }

                    HStack(spacing: 6) {
                        Spacer()
                        if let onOpenReport {
                            CDHoverIconButton(systemImage: "doc.text", helpText: "打开本地 Markdown 报告", action: onOpenReport)
                        }
                        if let onHandoff {
                            CDPillButton(
                                title: item.sessionHandle?.engine == .lody ? "打开 Lody" : "接管会话",
                                systemImage: item.sessionHandle?.engine == .lody ? "cube.transparent" : "terminal",
                                action: onHandoff
                            )
                        }
                        CDPillButton(title: "去审阅", systemImage: "arrow.up.right", action: onOpenSource)
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
    let onOpenReport: (() -> Void)?
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
        guard item.status == .completed else { return "已忽略" }
        if item.completionReason == .superseded {
            return "已进入第 \(item.reviewRound + 1) 轮"
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
                    if let onOpenReport {
                        CDHoverIconButton(systemImage: "doc.text", helpText: "打开本地报告", action: onOpenReport)
                    }
                    if let onHandoff {
                        CDHoverIconButton(
                            systemImage: item.sessionHandle?.engine == .lody ? "cube.transparent" : "terminal",
                            helpText: item.sessionHandle?.engine == .lody ? "打开 Lody 会话" : "接管本地会话",
                            action: onHandoff
                        )
                    }
                    CDHoverIconButton(systemImage: "arrow.up.right", helpText: "在浏览器打开", action: onOpenSource)
                }
                CDHoverIconButton(systemImage: "trash", helpText: "删除此条记录", action: onDelete)
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
