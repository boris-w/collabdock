# ITER-014：Review Token / 模型 / 成本统计面板（对标 Magpie × CodexBar + 原生 Swift Charts）

- **关联编号**：`REQ-007`、`REQ-010`、`REQ-014`
- **日期**：2026-11-27
- **状态**：已完成（41 项单测全绿，弹窗与设置页双视图离屏验真通过，`CollabDock.app` 与 `CollabDock-0.1.0.dmg` 已重建）

---

## 1. 核心能力

1. **四引擎真实 Token 与耗时采集**（`UsageModels.swift`、`AgentStreamParser.swift`、`AgentSessionRunner.swift`、`EnvironmentDetector.swift`）
   - **Claude Code**：采集 `input_tokens` / `output_tokens` / `cache_read_input_tokens` / `cache_creation_input_tokens` / 官方 `total_cost_usd` / `duration_ms`。
   - **Antigravity (`agy`)**：采集嵌套 `result.usage`（`input_tokens` / `output_tokens` / `thinking_tokens` / `cache_read_tokens` / `total_tokens`）与 `duration_seconds`。
   - **Codex CLI**：采集 `turn.completed` 事件的 `input_tokens` / `cached_input_tokens` / `output_tokens`。
   - **Lody (`lody.ai`)**：派发时落初始记录，打开统计页或点「同步 Lody」时通过官方 `lody session show <id> --json` 异步回补真实 `contextWindowUsage.used`、`lastModel` 与耗时，并透明标注 `上下文` 口径，绝不与精确分项混淆。
2. **本地 SQLite 独立用量账本与参考成本建模**（`SQLiteTaskStore.swift`、`AppSettings.swift`）
   - 新增本地表 `review_usage_runs`（100% 本地存储，含单模型、双模型会诊拆条与复审轮次）。
   - `UsageCostEstimator` 按公开单价估算 API 等价参考价值（Claude 官方上报值优先），支持设置页与弹窗内一键切换 **`USD ($)` / `CNY (¥)`**。
3. **双层原生可视化页面**（`UsageQuickStatsView.swift`、`UsageStatsSettingsView.swift`）
   - **菜单栏弹窗二级钻取（右上角柱状图按钮）**：`7天/30天/全部` 切换、3 格等宽 KPI 卡、Magpie 风格模型横向占比条、活跃仓库 Top 3、一键跳转完整统计。
   - **设置窗口第 6 个 Tab「用量统计」**：原生 **`Swift Charts`** 每日按引擎堆叠柱状图（支持切 `Token 消耗` / `审查次数`）、输入/输出/缓存/思考分项条、按模型汇总、最近 20 条审查流水与一键复制 CSV。

---

## 2. 验证结果

- `mobilebuildmcp swift-package test`：**41 passed, 0 failed, 0 skipped**（新增 `UsageAnalyticsTests` 覆盖四引擎解析、Lody `session show` 回补解析、多维度聚合、USD/CNY、CSV 导出与 SQLite 账本持久化）。
- 离屏视觉快照验证 `stats-popover-dark.png` 与 `settings-stats-light.png` 通过。
- `make dmg` 重建最新 `CollabDock.app` 与 `CollabDock-0.1.0.dmg`。
