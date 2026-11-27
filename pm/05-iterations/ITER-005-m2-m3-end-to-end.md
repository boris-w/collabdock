# ITER-005 · M2/M3 端到端全链路打通：原生通知、隔离 Worktree、四引擎真实调度与 GitHub Pending Draft 回写

- **日期**：2026-11-26
- **里程碑**：M2 + M3（核心端到端闭环达成）
- **涉及任务**：`TASK-010`, `TASK-011`, `TASK-012`, `TASK-013`, `TASK-015`（终端/Lody 一键接管）
- **关联决策**：`ADR-001`, `ADR-003`, `ADR-004`, `ADR-006`, `ADR-007`

---

## 1. 本轮落地内容

1. **隔离 Git Worktree 与本地仓库自动映射（`TASK-011`）**：
   - 新增 [WorktreeManager.swift](../../Sources/CollabDockCore/Workspace/WorktreeManager.swift)（含 `RepoScanner`）：自动扫描用户代码目录解析 `remote.origin.url` 建立 `owner/repo -> localPath` 映射；本机无仓时按需浅克隆（`git clone --filter=blob:none --no-checkout`）。
   - 通过 `git worktree add --detach` 在缓存目录创建只读隔离工作树并计算 `git diff origin/<base>...HEAD`，**100% 不碰用户原仓库分支与未提交修改**；对工单/群聊载荷自动复用关联仓或生成隔离 `context.md`。
2. **四引擎真实流式调度执行器与安全隔离（`TASK-012`）**：
   - 新增 [AgentStreamParser.swift](../../Sources/CollabDockCore/Agents/AgentStreamParser.swift) 与 [AgentSessionRunner.swift](../../Sources/CollabDockCore/Agents/AgentSessionRunner.swift)：
     - 统一拉起真实 `claude`、`codex`、`agy`、`lody` / `npx lody` 子进程，支持实时逐行解析流式进度推送到菜单栏卡片。
     - 强制从子进程环境变量剥离 `GITHUB_TOKEN` / `GH_TOKEN` / `GH_ENTERPRISE_TOKEN`（`REQ-008` 写权限隔离）。
     - 支持 `ProcessCancellationToken` 菜单栏一键安全中止。
     - 支持 `ADR-006` 双唤起模式（托管持久化 JSON Schema 解析 + 容错 Markdown 降级 / 原生 `claude --bg` 与 `lody session create` 后台会话派发）。
3. **GitHub Pending Review 草稿真实回写 + 本地 Markdown 报告（`TASK-013`）**：
   - 新增 [GitHubReviewFormatter.swift](../../Sources/CollabDockCore/Connectors/GitHub/GitHubReviewFormatter.swift) 并补齐 [GitHubConnector.swift](../../Sources/CollabDockCore/Connectors/GitHub/GitHubConnector.swift) `deliver(...)`：
     - 始终先落盘本地 Markdown 报告（`~/Library/Application Support/CollabDock/reports/`）。
     - 提交前经 `DiffLineValidator` 校验行号：有效行转为原生 Inline Comment（含 ```` ```suggestion ```` 代码建议块），越界行自动归拢到顶层 Summary 防止 422。
     - `platformDraft` 模式刻意省略 `event` 字段调用 `POST /repos/:owner/:repo/pulls/:number/reviews`，生成**仅自己可见的 GitHub Pending Review 草稿**；针对 GitHub 单 PR 仅允许 1 份未提交草稿的 422 返回友好提示。
4. **macOS 原生通知、开机自启与一键会话接管（`TASK-010`, `TASK-015`）**：
   - 新增 [SystemIntegrationService.swift](../../Sources/CollabDockApp/Services/SystemIntegrationService.swift)：接入 `UNUserNotificationCenter`（新任务抵达 & 草稿就绪弹窗 + 点击通知直达详情页）、`SMAppService.mainApp` 真实开机自启、一键打开本地 Markdown 报告，以及一键接管原会话（Lody 走 `lody://session/<id>?workspace=<ws>` Deep Link，Claude/Codex/Agy 自动拉起 Terminal 执行 `attach`/`--resume`）。
   - 历史草稿卡片新增「本地报告」「接管会话 / 打开 Lody」「去审阅」与失败卡片「重试」闭环。

---

## 2. 实测验证结果

- **单元测试（`mobilebuildmcp swift-package test`）**：**26 tests passed, 0 failed, 0 skipped**（新增 `WorktreeAndRepoScannerTests`、`AgentStreamParserTests`、`GitHubDeliveryTests` 覆盖真实临时 Git 仓扫描、流式 JSON/降级解析、Pending Review 无 `event` 键断言与 422 处理）。
- **Release 打包（`make app`）**：Swift 6 零告警通过，产出完整可运行原生 `build/CollabDock.app`。

---

## 3. 下一阶段（M4 · 团队正式分发与进阶能力）

- 端到端真实 PR 验收演练（`TASK-014`：在真实测试 PR 跑一遍 4 个引擎之一验证从通知到 GitHub Pending Review）。
- 团队正式分发流水线（`TASK-016`：Universal Binary + DMG 脚本 + Homebrew Cask + Sparkle 2 自动更新）。
- 多模型会诊（`TASK-017`）、第二个协作平台连接器（`TASK-019`，如飞书/GitLab）与三端原生 CLI 插件包（`TASK-018`）。
