# ITER-013：Re-request Review 去重修复、增量 Commit 复审与原会话续聊（`TASK-015` 闭环）

- **关联编号**：`TASK-015`、`REQ-002`、`REQ-010`、`REQ-014`、`ADR-006`、`ADR-007`
- **日期**：2026-11-27
- **状态**：已完成（38 项单测全绿，离屏视觉验真通过，`CollabDock.app` 与 `CollabDock-0.1.0.dmg` 已重建）

---

## 1. 背景与解决的核心问题

针对「开发根据 Review 意见修复并再次叫我 Review 同一个 PR」的高频场景，打通从**准确触发**到**原会话增量复审**的完整闭环：

1. **修复 Re-request Review 实时通知去重边界 Bug**（`GitHubConnector.swift`）
   - 此前 `/notifications` 通道中 `hydrateFromNotificationThread` 在 `review_requested` 场景下仍可能读取旧 `latest_comment_url` 的 `comment.id` 当去重键，若开发仅推新 Commit + 点 `Re-request review` 而未发新评论，可能被去重吞掉。
   - 现将 `review_requested` 通知的去重基线统一为 `pr.head.sha`（与 Search 通道格式完全对齐），同时将 `mention` 通知统一为 `c<comment.id>`，做到**既不漏单、也不双通道重复**。
2. **自动识别历史审查与轮次记忆**（`CollaborationModels.swift`、`AppCoordinator.swift`）
   - 新增 `PreviousReviewContext` 与 `ReviewContinuityMode`（`continueSessionIncremental` / `freshSessionIncremental` / `freshSessionFull`），并在 `CollaborationItem` 向后兼容解码中新增 `previousReview` 与 `reviewRound`。
   - 新通知入箱或手动粘贴同一 PR 链接时，自动从持久化记录匹配该 PR 最近一次已完成/草稿就绪的审查（`reviewedHeadSHA`、`engine`、`sessionID`、`summarySnippet`），收件箱标注 `第 N 轮复审`。
3. **真实 Git 增量 Diff 与 Force-Push 自动回退**（`WorktreeManager.swift`）
   - 新增 `computeIncrementalChanges(...)`：通过 `git merge-base --is-ancestor <oldSHA> <newHead>` 自动计算 `oldSHA..newHead` 的真实增量 Unified Diff 与 `git log --oneline` 新增提交清单；若检测到开发执行了 `rebase / force-push` 导致旧 SHA 不可达，自动标记 `wasForcePushed = true` 并平滑回退为最新全量 PR Diff。
4. **原会话续聊复审命令与确认卡片 UI**（`AgentCommandBuilder.swift`、`AgentSessionRunner.swift`、`TaskDetailView.swift`、`MenuBarContentView.swift`）
   - **Lody**：选中「续聊原会话 · 增量 Diff」时调用官方 `[npx -y] lody session chat --json <prevSessionId> <followUpPrompt>`，保留全部上轮记忆且不额外生成重复会话/worktree。
   - **Claude Code / Antigravity**：同引擎续聊时自动附加 `--resume <prevSessionId>`。
   - **确认卡片**：仅在复审场景出现琥珀色轮次条与「复审策略」菜单；选 Lody 续聊模式时自动精简无关参数行并展示「续聊目标：原 Lody 会话」，主 CTA 切为「续聊原 Lody 会话复审」。

---

## 2. 验证结果

- `mobilebuildmcp swift-package test`：**38 passed, 0 failed, 0 skipped**（新增 Re-request SHA 去重单测、`lody session chat` / `--resume` 命令与增量 Prompt 单测、真实临时 Git 仓增量 Diff & force-push 回退单测）。
- 离屏视觉快照验证 `detail-rereview-lody-dark.png`：布局干净、零裁切、主按钮语义清晰。
- `make dmg` 重建最新 `CollabDock.app` 与 `CollabDock-0.1.0.dmg`。
