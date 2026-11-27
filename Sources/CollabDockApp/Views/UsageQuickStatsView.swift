import SwiftUI
import CollabDockCore

/// 菜单栏二级钻取页：用量与参考成本速览（对标 Magpie × CodexBar，关联 ITER-014）
struct UsageQuickStatsView: View {
    @Bindable var coordinator: AppCoordinator
    let onBack: () -> Void
    let onOpenFullStats: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var selectedRange: UsageTimeRange = .last7Days

    private var report: UsageSummaryReport {
        coordinator.usageReport(for: selectedRange)
    }

    private var currency: UsageCurrency {
        coordinator.settings.usageCurrency
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            CDHairlineDivider(leadingInset: 0)

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    rangeControlRow
                    if report.totalRuns == 0 {
                        emptyCard
                    } else {
                        kpiStripCard
                        modelBreakdownCard
                        if !report.byScope.isEmpty {
                            repoBreakdownCard
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
            .scrollIndicators(.hidden)

            CDHairlineDivider(leadingInset: 0)
            bottomBar
        }
        .frame(width: CDTheme.popoverWidth, height: 524)
        .task {
            await coordinator.syncPendingLodyUsage()
        }
    }

    private var navBar: some View {
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

            Text("Review 用量统计")
                .font(.system(size: 12.5, weight: .semibold))

            Spacer()

            CDHoverIconButton(
                systemImage: coordinator.isSyncingLodyUsage ? "hourglass" : "arrow.clockwise",
                helpText: "回补已完成 Lody 会话的上下文用量"
            ) {
                Task { await coordinator.syncPendingLodyUsage() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var rangeControlRow: some View {
        HStack {
            HStack(spacing: 2) {
                ForEach([UsageTimeRange.last7Days, .last30Days, .allTime]) { range in
                    let selected = selectedRange == range
                    Button {
                        withAnimation(.snappy(duration: 0.14)) {
                            selectedRange = range
                        }
                    } label: {
                        Text(range.rawValue)
                            .font(.system(size: 11, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(
                                selected ? CDTheme.selectedTileFill(for: scheme) : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(CDTheme.subtleSurface(for: scheme), in: Capsule())

            Spacer()

            Button {
                coordinator.settings.usageCurrency = (currency == .usd) ? .cny : .usd
            } label: {
                Text(currency.displayName)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(CDTheme.subtleSurface(for: scheme), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("点击切换参考费用币种 (USD / CNY)")
        }
    }

    private var kpiStripCard: some View {
        CDInsetCard {
            HStack(spacing: 0) {
                kpiCell(
                    title: "审查次数",
                    value: "\(report.totalRuns)",
                    sub: report.reReviewCount > 0 ? "含 \(report.reReviewCount) 次复审" : "\(report.uniqueReviewTargetCount) 个 PR"
                )
                Rectangle()
                    .fill(CDTheme.hairlineBorder(for: scheme))
                    .frame(width: 0.5)
                    .padding(.vertical, 10)
                kpiCell(
                    title: "总 Token",
                    value: UsageAggregator.formatCompactTokens(report.totalTokens),
                    sub: tokenSubLabel
                )
                Rectangle()
                    .fill(CDTheme.hairlineBorder(for: scheme))
                    .frame(width: 0.5)
                    .padding(.vertical, 10)
                kpiCell(
                    title: "参考价值",
                    value: currency.format(usd: report.totalEstimatedCostUSD),
                    sub: report.averageDurationSeconds.map { "均 \(UsageAggregator.formatDuration($0))" } ?? "API 等价"
                )
            }
            .padding(.vertical, 10)
        }
    }

    private var tokenSubLabel: String {
        if let hit = report.cacheHitRate {
            return String(format: "缓存命中 %.0f%%", hit * 100)
        }
        if report.contextWindowTokensTotal > 0 && report.exactTokensTotal == 0 {
            return "Lody 上下文"
        }
        if report.pendingSyncLodyCount > 0 {
            return "\(report.pendingSyncLodyCount) 条待同步"
        }
        return "实测累计"
    }

    private func kpiCell(title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(sub)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
    }

    private var modelBreakdownCard: some View {
        let maxTokens = max(1, report.byModel.map(\.totalTokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("按模型分布")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("次数 · Token · 参考价值")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            CDInsetCard {
                VStack(spacing: 0) {
                    ForEach(Array(report.byModel.prefix(5).enumerated()), id: \.element.id) { idx, bucket in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(bucket.engine.brandAccent)
                                    .frame(width: 6, height: 6)
                                Text(bucket.displayName)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                                if bucket.metricKind == .contextWindow {
                                    Text("上下文")
                                        .font(.system(size: 8.5, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(CDTheme.subtleSurface(for: scheme), in: Capsule())
                                }
                                Spacer(minLength: 6)
                                Text("\(bucket.runCount)次")
                                    .font(.system(size: 10.5).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(UsageAggregator.formatCompactTokens(bucket.totalTokens))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                Text(currency.format(usd: bucket.estimatedCostUSD))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }

                            GeometryReader { geo in
                                let ratio = bucket.totalTokens > 0
                                    ? max(0.05, CGFloat(bucket.totalTokens) / CGFloat(maxTokens))
                                    : 0.04
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(CDTheme.subtleSurface(for: scheme))
                                    Capsule()
                                        .fill(bucket.engine.brandAccent.opacity(0.78))
                                        .frame(width: geo.size.width * ratio)
                                }
                            }
                            .frame(height: 4)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8.5)

                        if idx < min(5, report.byModel.count) - 1 {
                            CDHairlineDivider(leadingInset: 11)
                        }
                    }
                }
            }
        }
    }

    private var repoBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("活跃仓库 Top 3")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            CDInsetCard {
                VStack(spacing: 0) {
                    ForEach(Array(report.byScope.prefix(3).enumerated()), id: \.element.id) { idx, scope in
                        HStack {
                            Text(scope.scope)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text("\(scope.runCount) 次")
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("·")
                                .foregroundStyle(.quaternary)
                            Text(UsageAggregator.formatCompactTokens(scope.totalTokens))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7.5)

                        if idx < min(3, report.byScope.count) - 1 {
                            CDHairlineDivider(leadingInset: 11)
                        }
                    }
                }
            }
        }
    }

    private var emptyCard: some View {
        CDInsetCard(padding: 22) {
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("暂无审查用量记录")
                    .font(.system(size: 13, weight: .semibold))
                Text("通过 CollabDock 确认执行 PR 审查后，会自动记录各模型消耗的 Token、耗时与参考价值。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if coordinator.settings.developerModeEnabled {
                    CDPillButton(title: "加载示例统计数据", systemImage: "sparkles") {
                        coordinator.loadDemoUsageRuns()
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var bottomBar: some View {
        HStack {
            if coordinator.settings.developerModeEnabled && coordinator.hasDemoUsageRuns {
                Button {
                    coordinator.clearDemoUsageRuns()
                } label: {
                    Text("DEV 示例 · 清空")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CDTheme.statusAmber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CDTheme.statusAmber.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("当前包含开发者模式示例统计（点击一键清空，不影响真实 SQLite 数据）")
            } else if report.pendingSyncLodyCount > 0 {
                Text("\(report.pendingSyncLodyCount) 条 Lody 会话待回补")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            } else {
                Text("100% 本地 SQLite 统计")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                onOpenFullStats()
            } label: {
                HStack(spacing: 3) {
                    Text("完整图表与明细")
                        .font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
