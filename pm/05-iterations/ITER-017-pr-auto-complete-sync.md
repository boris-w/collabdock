# ITER-017：PR Approve / 合并 / 关闭自动归档闭环（单次 GraphQL 批量对齐）

- **关联编号**：`REQ-002`、`REQ-003`、`REQ-010`
- **日期**：2026-11-27
- **状态**：已完成（46 项单测全绿，`CollabDock.app` 与 `CollabDock-0.1.0.dmg` 已重建）

---

## 1. 核心设计
1. **单次批量 GraphQL 轻量同步**（`GitHubConnector.swift`）
   - 收件箱中无活跃 GitHub PR 时 **0 请求、0 配额消耗**；有活跃 PR 时一次 GraphQL 请求批量查回最多 25 条 PR 的 `state`、`merged`、`headRefOid` 及本人最近 20 条 Review 结论（恒仅占 1 点配额）。
   - 在常规轮询、手动刷新以及打开菜单栏弹窗时（带 25 秒节流）自动触发。
2. **严格归档规则与多轮复审防误杀**（`GitHubConnector.evaluatePRAutoCompletion`、`AppCoordinator.swift`）
   - **`APPROVED`**（命中当前轮次 commit SHA 或提交于本轮入箱之后）→ 自动归档，标记 `已 Approve`。
   - **`MERGED` / `CLOSED`** → 自动归档，标记 `已合并` / `已关闭`。
   - **`CHANGES_REQUESTED`** → **不归档**，继续留在收件箱并给卡片标示琥珀色 `待修复` 徽章，等待作者修复后进入下一轮复审。
   - 忽略 `PENDING` 草稿与历史轮次的旧 `APPROVED`，且绝不打断正在运行中的本地 CLI / Lody 审查。
3. **可控设置与已完成明细**（`AppSettings.swift`、`SettingsView.swift`、`MenuBarContentView.swift`）
   - `设置 → 触发规则` 新增「自动归档规则」总开关（默认开启）。
   - 「已完成」归档行按结束原因展示差异化图标与文案（`已 Approve` / `已合并` / `已关闭` / `已完成`）。

## 2. 验证结果
- `mobilebuildmcp swift-package test`：**46 passed, 0 failed, 0 skipped**（新增 `PRAutoCompletionTests` 覆盖真实 GraphQL JSON 解析、`APPROVED`/`CHANGES_REQUESTED`/`MERGED`/`CLOSED`/`PENDING`/`DISMISSED` 与第 2 轮复审防误杀）。
- `make dmg` 重建最新 `CollabDock.app` 与 `CollabDock-0.1.0.dmg`。
