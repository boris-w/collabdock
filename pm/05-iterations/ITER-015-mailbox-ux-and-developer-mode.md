# ITER-015：邮件式极简收件箱重构与隐藏开发者模式

- **关联编号**：`REQ-002`、`REQ-003`、`REQ-007`、`REQ-014`
- **日期**：2026-11-27
- **状态**：已完成（43 项单测全绿，空态收件箱 / 有数据收件箱 / 已完成归档离屏验真通过，`CollabDock.app` 与 `CollabDock-0.1.0.dmg` 已重建）

---

## 1. 核心变更

1. **菜单栏首页极致精简**（`MenuBarContentView.swift`）
   - 移除首页底部冗余的 `Claude / Codex / Agy / Lody · 默认引擎` 胶囊条（引擎选择回归「设置 → AI 引擎」与单条 PR 确认卡片）。
   - 移除底栏工程味文案 `· 只读沙箱`，底栏精简为 `● @username`（点击即可轻切换暂停/恢复轮询）+ `退出`；顶部图标从 5 个精简为 4 个（统计 / `+` 导入 / 刷新 / 设置）。
2. **邮件式管理流转：`收件箱` + `已完成` + 删除**（`CollaborationModels.swift`、`AppCoordinator.swift`、`MenuBarContentView.swift`）
   - 重定义 `CollaborationTaskStatus.isInboxActive`：所有尚需关注/操作的状态（`pendingConfirmation`、`running`、`draftReady`、`failed`）统一留在 **收件箱**；不再把失败条目错误计入「草稿」。
   - 新增「标为已完成（`✓`）」、「单条删除（`🗑`）」与「清空已完成」闭环；删除列表记录时同步清理 `collaboration_items`，但**严格保留 `seen_events` 去重记录与 `review_usage_runs` 本地用量账本**。
3. **隐藏触发的「开发者模式」与隔离示例数据**（`AppSettings.swift`、`SettingsView.swift`、`UsageQuickStatsView.swift`、`UsageStatsSettingsView.swift`）
   - 默认对普通用户 100% 隐藏全部测试/示例数据按钮（原「协作来源」页的常驻预览卡片已收归开发者模式）。
   - **两种隐藏触发方式**：
     1. 在 `设置 → 工作区` 底部版本行 `CollabDock v0.1.0` **连续点击 5 次**；
     2. 在设置窗口任意页按下快捷键 **`⌘⇧D`**。
   - 解锁后可在 `设置 → 工作区 → 开发者模式` 以及「用量统计」弹窗/设置页一键加载或清空演示任务与跨 5 天/四引擎示例统计数据（仅驻留内存，`demo-usage-` 前缀隔离，关闭开发者模式时自动清空，绝不污染真实 SQLite 账本）。
4. **顺手加固**（`EnvironmentDetector.swift`）
   - `DefaultProcessRunner` 固定 `currentDirectoryURL = FileManager.default.temporaryDirectory`，防止在含局部 `package.json` 的目录执行 `npx -y lody` 时被劫持。

---

## 2. 验证结果

- `mobilebuildmcp swift-package test`：**43 passed, 0 failed, 0 skipped**（新增邮件式状态语义、删除保留用量账本与 `developerModeEnabled` 持久化单测）。
- 离屏视觉快照验证 `inbox-empty-light.png`、`inbox-light.png`、`completed-light.png` 通过。
- `make dmg` 重建最新 `CollabDock.app` 与 `CollabDock-0.1.0.dmg`。
