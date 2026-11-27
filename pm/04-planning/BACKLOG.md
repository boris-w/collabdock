# 04 · 任务待办与进度看板（Backlog）

> ⚠️ **已冻结（2026-11-27）**：迭代改为 GitHub PR，待办迁移到 GitHub Issues。本文件仅作历史参考，内容停留在冻结时的状态。

> 状态图例：`✅ Done` | `🚧 In Progress` | `🔜 Next` | `📋 Todo` | `⏸ Blocked`

---

## M0 · 立项、可追溯 PM 体系与工程骨架

| 任务 ID | 任务名称 | 关联需求 | 关联决策 | 状态 | 备注 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `TASK-001` | 建立全流程可追溯 `pm/` 项目管理体系与立项基线文档 | REQ-001~012 | ADR-001~004 | ✅ Done | 完成 6 阶段目录、PRD、UX、ADR、Roadmap 与追溯矩阵 |
| `TASK-002` | 初始化 SwiftPM 双 Target（`ReviewDockCore` + `ReviewDockApp`）与 `.app` 打包脚本 | REQ-004, REQ-011 | ADR-001 | ✅ Done | 含基础领域模型、规则引擎、三端命令构造器、Diff 校验器与可运行菜单栏骨架 |
| `TASK-003` | 搭建核心单元测试套件并验证 `swift build` / `swift test` / `make app` | REQ-003, REQ-007, REQ-009 | ADR-001, ADR-003 | ✅ Done | 验证规则匹配、命令只读沙箱参数与 Diff 行号校验 |

---

## M1 · GitHub 事件监听、规则引擎与持久化状态机

| 任务 ID | 任务名称 | 关联需求 | 关联决策 | 状态 | 备注 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `TASK-004` | 实现 `EnvironmentDetector`（GUI `PATH` 补全、`gh` / `git` / `claude` / `codex` / `agy` 探测与 `agy models` 拉取） | REQ-001, REQ-007 | ADR-001 | ✅ Done | 实时探测路径、版本、`gh` 权限与全部 `agy models` |
| `TASK-005` | 实现 `GitHubConnector`（`gh auth token` + `If-Modified-Since` 304 轮询 + `X-Poll-Interval` + 缺 scope 自动降级 Search API） | REQ-001, REQ-002 | ADR-002, ADR-005 | ✅ Done | 覆盖 304 / 200 / 403 降级 Mock HTTP 单测 |
| `TASK-006` | 实现 `SQLiteTaskStore` 持久化与幂等去重状态机 | REQ-002, REQ-004 | ADR-002 | ✅ Done | `actor` 隔离 + macOS 内置 `SQLite3` WAL 模式 |
| `TASK-007` | 实现 `SettingsStore` 持久化与团队配置包导出/非破坏性合并 | REQ-003, REQ-011 | ADR-004, ADR-005 | ✅ Done | 自动落盘 `settings.json`，支持复制团队 JSON |
| `TASK-020` | 追加 `Lody (lody.ai)` 一等支持（四引擎探测、`lody/npx lody session create` 命令构造、Deep Link 与设置项） | REQ-014 | ADR-007 | ✅ Done | 选中 Lody 默认走原生后台会话并适配 UI |

---

## M2 · 原生 SwiftUI 菜单栏体验与系统触达

| 任务 ID | 任务名称 | 关联需求 | 关联决策 | 状态 | 备注 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `TASK-008` | 菜单栏收件箱、多平台过滤、二级确认画布（含双驱动唤起模式）与实时状态联动 | REQ-004, REQ-005 | ADR-001, ADR-005, ADR-006 | ✅ Done | 已接入实时环境体检与真实 GitHub 同步 |
| `TASK-009` | 5 Tab 原生 `Settings` 设置窗口（协作来源/触发规则/AI 引擎体检/工作区/团队模板） | REQ-001, REQ-003, REQ-011 | ADR-001, ADR-005 | ✅ Done | 展示真实 `gh` 认证态、CLI 版本与模型数 |
| `TASK-010` | 集成 `UNUserNotificationCenter` 原生通知点击直达与 `SMAppService` 开机自启 | REQ-004 | ADR-001 | ✅ Done | 已接入 `SystemIntegrationService` 并做 `.app` Bundle 安全守卫 |

---

## M3 · 隔离执行、四引擎真实调度与 Pending Draft 回写

| 任务 ID | 任务名称 | 关联需求 | 关联决策 | 状态 | 备注 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `TASK-011` | 实现 `RepoScanner` 与 `WorktreeManager`（本地仓映射、按需浅克隆、隔离 `git worktree` 与 Diff 计算） | REQ-006 | ADR-003, ADR-005 | ✅ Done | 绝不污染当前分支，含临时 Git 仓单测 |
| `TASK-012` | 实现 `AgentStreamParser` 与 `AgentSessionRunner`（四引擎真实流式子进程、剥离 GitHub Token、安全中止与双驱动） | REQ-007, REQ-008, REQ-014 | ADR-003, ADR-006, ADR-007 | ✅ Done | 支持托管结构化运行与 `claude --bg`/`lody` 后台派发 |
| `TASK-013` | 实现 `GitHubReviewFormatter` 与 `GitHubConnector.deliver`（Pending Draft 回写、Suggestion 块、越界降级与本地报告） | REQ-009 | ADR-004 | ✅ Done | 含无 `event` 键草稿与 422 冲突 Mock HTTP 单测 |
| `TASK-014` | 真实 PR 端到端验收（在真实仓库跑通 PR 导入/监听 -> 隔离上下文 -> Lody 派发与本地 CLI 结构化审查全链路） | REQ-002~009, REQ-014 | ADR-002~004, ADR-007 | ✅ Done | 已在真实 PR `boris-w/Lody#1` 实测跑通 Lody 派发与本地 `agy` 隔离 Worktree 审查，并修复 5 处真实环境问题 |

---

## M4 · 团队分发与进阶能力

| 任务 ID | 任务名称 | 关联需求 | 关联决策 | 状态 | 备注 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `TASK-015` | 实现一键接管原会话（Lody Deep Link / Terminal `--resume`/`attach`）与增量 Commit 复审（含 Lody `session chat` 续聊） | REQ-010 | ADR-003, ADR-006, ADR-007 | ✅ Done | 已完成一键接管、Re-request SHA 去重修复、增量 Diff（兼容 force-push）与原会话续聊复审 |
| `TASK-016` | 实现团队正式分发流水线（原生 AppIcon、Universal Binary、DMG 打包脚本、Homebrew Cask 模板与团队配置导入导出） | REQ-011 | ADR-004 | ✅ Done | `make dmg` 已实测产出安装包与 SHA256；正式签名公证凭证书触发 |
| `TASK-017` | 实现多模型会诊模式（同一只读 Worktree 并行执行 2 个引擎/模型并汇总共识问题） | REQ-010 | ADR-003 | ✅ Done | 含 `CouncilSynthesizer` 共识合并单测与折叠式 UI |
| `TASK-018` | 打包 Claude Code / Codex / Antigravity 配套原生插件（共享 Skill + 本地队列 MCP） | REQ-012 | ADR-001 | 📋 Todo | 会话内 `/collab-inbox` 认领任务 |
| `TASK-019` | 实现第二个协作平台连接器（飞书 / GitLab / Linear 按团队优先级择一热插拔接入） | REQ-013 | ADR-005 | 📋 Todo | 直接复用 `CollaborationConnector`、规则引擎与二级确认画布 |
