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
        case tokens = "Token 消耗"
        case runs = "审查次数"
        var id: String { rawValue }
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
                    Picker("时间范围", selection: $selectedRange) {
                        ForEach(UsageTimeRange.allCases) { r in
                            Text(r.rawValue).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)

                    Spacer()

                    Picker("币种", selection: $coordinator.settings.usageCurrency) {
                        ForEach(UsageCurrency.allCases) { cur in
                            Text(cur.displayName).tag(cur)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)

                    Button(coordinator.isSyncingLodyUsage ? "同步中..." : "同步 Lody") {
                        Task { await coordinator.syncPendingLodyUsage() }
                    }
                    .controlSize(.small)
                    .disabled(coordinator.isSyncingLodyUsage)

                    Button(copiedCSVHint ? "已复制 CSV" : "复制 CSV") {
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
                            Button("清空示例") {
                                coordinator.clearDemoUsageRuns()
                            }
                            .controlSize(.small)
                        } else {
                            Button("加载示例") {
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
                        Text("当前展示含开发者模式示例统计数据（仅内存预览，绝不写入本地 SQLite 账本）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if report.totalRuns == 0 {
                Section("用量总览") {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("所选时间范围内暂无 Review 用量记录")
                            .font(.subheadline.weight(.medium))
                        Text("通过 CollabDock 派发到 Lody 或本地 CLI（Claude / Codex / Antigravity）审查 PR 后，将自动采集并汇总 Token、模型与参考 API 价值。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if coordinator.settings.developerModeEnabled {
                            Button("加载示例统计数据") {
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
                Section("核心指标总览") {
                    HStack(spacing: 12) {
                        metricTile(
                            title: "审查次数",
                            value: "\(report.totalRuns)",
                            detail: "\(report.uniqueReviewTargetCount) 个 PR · \(report.reReviewCount) 次复审"
                        )
                        metricTile(
                            title: "累计 Token",
                            value: UsageAggregator.formatCompactTokens(report.totalTokens),
                            detail: tokenBreakdownDetail
                        )
                        metricTile(
                            title: "参考 API 价值",
                            value: currency.format(usd: report.totalEstimatedCostUSD),
                            detail: report.cacheHitRate.map { String(format: "缓存命中 %.0f%%", $0 * 100) } ?? "按官方公开单价估算"
                        )
                        metricTile(
                            title: "平均耗时",
                            value: report.averageDurationSeconds.map { UsageAggregator.formatDuration($0) } ?? "-",
                            detail: report.pendingSyncLodyCount > 0 ? "\(report.pendingSyncLodyCount) 条 Lody 待同步" : "本地实时统计"
                        )
                    }
                    .padding(.vertical, 4)

                    if report.exactTokensTotal > 0 {
                        HStack(spacing: 14) {
                            tokenChip(label: "输入", value: report.totalInputTokens)
                            tokenChip(label: "输出", value: report.totalOutputTokens)
                            tokenChip(label: "缓存读取", value: report.totalCacheReadTokens)
                            tokenChip(label: "思考", value: report.totalThinkingTokens)
                            Spacer()
                            if report.contextWindowTokensTotal > 0 {
                                Text("另有 Lody 上下文 \(UsageAggregator.formatCompactTokens(report.contextWindowTokensTotal))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Section {
                    Chart(report.dailyTrend) { point in
                        BarMark(
                            x: .value("日期", point.day, unit: .day),
                            y: .value(
                                chartMetric == .tokens ? "Tokens" : "次数",
                                chartMetric == .tokens ? point.totalTokens : point.runCount
                            )
                        )
                        .foregroundStyle(by: .value("引擎", point.engine.shortName))
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
                        Text("每日趋势")
                        Spacer()
                        Picker("", selection: $chartMetric) {
                            ForEach(ChartMetric.allCases) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 164)
                    }
                }

                Section("按模型汇总") {
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
                                Text("\(bucket.runCount) 次")
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

                Section("最近审查明细（最新 20 条）") {
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
                                    Text(run.usage.metricKind == .pendingSync ? "待同步" : UsageAggregator.formatCompactTokens(run.usage.totalTokens))
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
            return "含 CLI 精确 + Lody 上下文"
        }
        if report.contextWindowTokensTotal > 0 {
            return "Lody 会话上下文总量"
        }
        return "直连 CLI 精确采集"
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
