# ITER-012：仓库目录映射可视化、多副本切换与单次 Worktree/主目录自由切换

- **关联编号**：`REQ-006`、`REQ-014`
- **日期**：2026-11-26
- **状态**：已完成（35 项单测全绿，离屏视觉验收通过，`CollabDock.app` 与 `CollabDock-0.1.0.dmg` 已重建）

## 背景与改动
针对用户「想看清并能自由修改 PR 对应的本地项目目录（如 `backend` / `backend-2`），默认独立 Worktree、按需可改」的诉求：
1. **数据模型与目录覆盖优先级**（`AppSettings.swift`、`CollaborationModels.swift`、`WorktreeManager.swift`、`AgentCommandBuilder.swift`）
   - `AppSettings` 新增 `repositoryDirectoryOverrides: [String: String]`（向后兼容解码）；`ExecutionPlan` 新增 `targetDirectoryOverride: String?` 与 `useIsolatedWorktree: Bool`（默认 `true`）。
   - 解析顺序：`单次任务覆盖` → `设置页固定映射` → `Lody 本地项目 / 代码根目录扫描` → `缓存浅克隆`；当切换为「直用主目录（`useIsolatedWorktree = false`）」时，Lody 自动省略 `--worktree`/`--branch` 避免切换用户当前分支，`WorktreeManager` 亦仅计算 Diff 而不改当前分支。
2. **设置页 → 工作区升级**（`SettingsView.swift`、`AppCoordinator.swift`）
   - 直接展示所有自动发现与手动固定的「`owner/repo` → 本地目录」映射清单，同仓库存在多个本地副本（如 `backend` 与 `backend-2`）时提供一键「切换副本」菜单，并支持原生 Finder 弹窗选目录固定、重置与手动绑定新仓库。
3. **确认卡片新增「项目目录」一行**（`TaskDetailView.swift`）
   - 派发前直显当前目录与隔离方式（如 `backend · 独立 Worktree`），点开即可一键切「独立 Worktree / 直用主目录」、切换本地副本或通过 `NSOpenPanel` 临时指定任意目录。
