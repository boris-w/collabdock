import AppKit
import Charts
import SwiftUI
import CollabDockCore

/// 设置窗口第 6 个 Tab：原生 Swift Charts 趋势图、模型成本汇总与审查明细流水（关联 ITER-014）
struct UsageStatsSettingsView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var selectedRange: UsageTimeRange = .last30Days
    @State private var chartMetric: ChartMetric = .tokens
    @State private var copiedCSVHint: Bool = false

    enum ChartMetric: String, CaseIterable, Identifiable {
        case tokens = "tokens"
        case runs = "runs"
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .tokens: return L("Tokens")
            case .runs: return L("Reviews")
            }
        }
    }

    private var report: UsageSummaryReport {
        coordinator.usageReport(for: selectedRange)
    }

    private var currency: UsageCurrency {
        coordinator.settings.usageCurrency
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Picker(L("Time Range"), selection: $selectedRange) {
                        ForEach(UsageTimeRange.allCases) { r in
                            Text(r.displayName).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)

                    Spacer()

                    Picker(L("Currency"), selection: $coordinator.settings.usageCurrency) {
                        ForEach(UsageCurrency.allCases) { cur in
                            Text(cur.displayName).tag(cur)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)

                    Button(coordinator.isSyncingLodyUsage ? L("Syncing...") : L("Sync Lody")) {
                        Task { await coordinator.syncPendingLodyUsage() }
                    }
                    .controlSize(.small)
                    .disabled(coordinator.isSyncingLodyUsage)

                    Button(copiedCSVHint ? L("Copied CSV") : L("Copy CSV")) {
                        let csv = UsageAggregator.exportCSV(runs: report.filteredRuns, currency: currency)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(csv, forType: .string)
                        copiedCSVHint = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copiedCSVHint = false
                        }
                    }
                    .controlSize(.small)
                    .disabled(report.filteredRuns.isEmpty)

                    if coordinator.settings.developerModeEnabled {
                        if coordinator.hasDemoUsageRuns {
                            Button(L("Clear Sample")) {
                                coordinator.clearDemoUsageRuns()
                            }
                            .controlSize(.small)
                        } else {
                            Button(L("Load Sample")) {
                                coordinator.loadDemoUsageRuns()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                if coordinator.settings.developerModeEnabled && coordinator.hasDemoUsageRuns {
                    HStack(spacing: 6) {
                        Text("DEV")
                            .font(.caption2.weight(.semibold).monospaced())
                            .foregroundStyle(CDTheme.statusAmber)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(CDTheme.statusAmber.opacity(0.14), in: Capsule())
                        Text(L("Showing Developer Mode sample stats (in-memory preview only; never written to SQLite)."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if report.totalRuns == 0 {
                Section(L("Usage Overview")) {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text(L("No review usage in the selected range"))
                            .font(.subheadline.weight(.medium))
                        Text(L("Run PR reviews via Lody to track context usage, models, and estimated API cost."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if coordinator.settings.developerModeEnabled {
                            Button(L("Load Sample Stats")) {
                                coordinator.loadDemoUsageRuns()
                            }
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section(L("Overview")) {
                    HStack(spacing: 12) {
                        metricTile(
                            title: L("Reviews"),
                            value: "\(report.totalRuns)",
                            detail: L("%1$lld PRs · %2$lld re-reviews", report.uniqueReviewTargetCount, report.reReviewCount)
                        )
                        metricTile(
                            title: L("Total Tokens"),
                            value: UsageAggregator.formatCompactTokens(report.totalTokens),
                            detail: tokenBreakdownDetail
                        )
                        metricTile(
                            title: L("Est. API Cost"),
                            value: currency.format(usd: report.totalEstimatedCostUSD),
                            detail: report.cacheHitRate.map { L("Cache %.0f%%", $0 * 100) } ?? L("Based on public API list prices")
                        )
                        metricTile(
                            title: L("Avg Duration"),
                            value: report.averageDurationSeconds.map { UsageAggregator.formatDuration($0) } ?? "-",
                            detail: report.pendingSyncLodyCount > 0 ? L("%lld Lody pending", report.pendingSyncLodyCount) : L("Local live ledger")
                        )
                    }
                    .padding(.vertical, 4)

                    if report.exactTokensTotal > 0 {
                        HStack(spacing: 14) {
                            tokenChip(label: L("Input"), value: report.totalInputTokens)
                            tokenChip(label: L("Output"), value: report.totalOutputTokens)
                            tokenChip(label: L("Cache Read"), value: report.totalCacheReadTokens)
                            tokenChip(label: L("Thinking"), value: report.totalThinkingTokens)
                            Spacer()
                            if report.contextWindowTokensTotal > 0 {
                                Text(L("Plus Lody context %@", UsageAggregator.formatCompactTokens(report.contextWindowTokensTotal)))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Section {
                    Chart(report.dailyTrend) { point in
                        BarMark(
                            x: .value(L("Date"), point.day, unit: .day),
                            y: .value(
                                chartMetric == .tokens ? L("Tokens") : L("Reviews"),
                                chartMetric == .tokens ? point.totalTokens : point.runCount
                            )
                        )
                        .foregroundStyle(by: .value(L("Engine"), point.engine.shortName))
                        .cornerRadius(3)
                    }
                    .chartForegroundStyleScale([
                        AgentEngine.claudeCode.shortName: AgentEngine.claudeCode.brandAccent,
                        AgentEngine.codex.shortName: AgentEngine.codex.brandAccent,
                        AgentEngine.antigravity.shortName: AgentEngine.antigravity.brandAccent,
                        AgentEngine.lody.shortName: AgentEngine.lody.brandAccent
                    ])
                    .chartYAxis {
                        AxisMarks(position: .leading) { val in
                            AxisGridLine().foregroundStyle(Color.secondary.opacity(0.14))
                            AxisValueLabel {
                                if let intVal = val.as(Int.self) {
                                    Text(chartMetric == .tokens ? UsageAggregator.formatCompactTokens(intVal) : "\(intVal)")
                                        .font(.caption2.monospacedDigit())
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
                                .font(.caption2)
                        }
                    }
                    .frame(height: 150)
                    .padding(.vertical, 4)
                } header: {
                    HStack {
                        Text(L("Daily Trend"))
                        Spacer()
                        Picker("", selection: $chartMetric) {
                            ForEach(ChartMetric.allCases) { m in
                                Text(m.displayName).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 164)
                    }
                }

                Section(L("By Model")) {
                    let maxTokens = max(1, report.byModel.map(\.totalTokens).max() ?? 1)
                    ForEach(report.byModel) { bucket in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(bucket.engine.brandAccent)
                                    .frame(width: 7, height: 7)
                                Text(bucket.displayName)
                                    .font(.subheadline.weight(.medium))
                                Text(bucket.metricKind.badgeLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                                Spacer()
                                Text(L("%lld runs", bucket.runCount))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(UsageAggregator.formatCompactTokens(bucket.totalTokens))
                                    .font(.caption.weight(.semibold).monospaced())
                                    .frame(width: 60, alignment: .trailing)
                                Text(currency.format(usd: bucket.estimatedCostUSD))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .trailing)
                            }

                            GeometryReader { geo in
                                let ratio = bucket.totalTokens > 0
                                    ? max(0.04, CGFloat(bucket.totalTokens) / CGFloat(maxTokens))
                                    : 0.03
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.12))
                                    Capsule()
                                        .fill(bucket.engine.brandAccent.opacity(0.8))
                                        .frame(width: geo.size.width * ratio)
                                }
                            }
                            .frame(height: 4)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section(L("Recent Reviews (Latest 20)")) {
                    ForEach(report.filteredRuns.prefix(20)) { run in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(run.engine.brandAccent)
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(run.displayContextTag)
                                        .font(.caption.weight(.medium).monospaced())
                                    if run.reviewRound > 1 {
                                        Text("R\(run.reviewRound)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(CDTheme.statusAmber)
                                    }
                                    Text(run.displayModelKey)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text(run.title)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(run.usage.metricKind == .pendingSync ? run.usage.metricKind.badgeLabel : UsageAggregator.formatCompactTokens(run.usage.totalTokens))
                                        .font(.caption.weight(.medium).monospaced())
                                    Text(currency.format(usd: run.estimatedCostUSD))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 4) {
                                    if let dur = run.usage.durationSeconds, dur > 0 {
                                        Text(UsageAggregator.formatDuration(dur))
                                    }
                                    Text(run.createdAt, format: .dateTime.month(.defaultDigits).day().hour().minute())
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await coordinator.syncPendingLodyUsage()
        }
    }

    private var tokenBreakdownDetail: String {
        if report.exactTokensTotal > 0 && report.contextWindowTokensTotal > 0 {
            return L("Legacy CLI + Lody context")
        }
        if report.contextWindowTokensTotal > 0 {
            return L("Lody session context total")
        }
        return L("Legacy CLI exact measurement")
    }

    private func metricTile(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tokenChip(label: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(UsageAggregator.formatCompactTokens(value))
                .font(.caption2.weight(.medium).monospaced())
        }
    }
}
