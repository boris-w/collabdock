# ADR-007 · 将 Lody.ai 集成为一等本地协作执行与会话编排目标

- **状态**：已采纳；[ADR-008](ADR-008-lody-only-execution.md)（2026-11-28）起 Lody 是唯一执行方式
- **日期**：2026-11-26
- **关联需求**：[REQ-014](../../02-product/PRD.md#req-014--lodyai-本地工作区与会话编排深度集成p1)
- **关联决策**：扩展 `ADR-003`、`ADR-006`

## 背景

团队本地日常已经在使用开源 AI Agent 协作工作区 **Lody (`lody.ai` / `LodyAI/Lody`)** 来统一托管 Claude Code、Codex、Antigravity 等 ACP Agent、隔离 Git Worktree 并实现桌面端/Web/iOS 多端会话同步。如果 CollabDock 仅支持直连三大原始 CLI，本地用 Lody 的开发者无法把外部协作事件无缝派发到自己的 Lody 侧栏会话中。

## 决策

将 **`Lody (lody.ai)`** 加入 `AgentEngine` 作为第四个一等执行/编排目标（与 `Claude Code`、`Codex`、`Antigravity` 并列）：

1. **官方公开 CLI 派发（零私有逆向依赖）**：
   - 使用 Lody 官方 CLI `lody session create --json [--workspace <ws>] [--agent-config <cfg>] [--repo <owner/repo>] "<prompt>"`。
   - 若用户本机未全局安装 `lody` 二进制，按配置支持自动回退到官方 `npx lody session create ...`。
2. **原生 Worktree 与多端会话同步**：
   - 选中 `Lody` 时默认采用 `.nativeBackgroundSession` 唤起模式，并通过 `--repo` 交由 Lody 原生管理隔离 Git Worktree，任务一经确认即实时出现在 Lody Desktop / Web / iOS 侧边栏。
3. **官方 Deep Link 一键直达**：
   - 依据官方 `lody://session/<sessionId>?workspace=<workspaceId>` 规范生成一键跳转链接，点击即可拉起 Lody Desktop 查看完整实时 Diff 与继续对话。
4. **环境探测兼容**：
   - `EnvironmentDetector` 依次检测全局 `lody` CLI、`/Applications/Lody.app` 与 `npx` 回退能力，并在设置页提供专属 `LodyConfig` 配置区。

## 影响与权衡

- **正面**：本地已在用 Lody 的开发者获得最丝滑的体验（CollabDock 负责「外部事件监听 + 人工确认门控 + 选配置」，Lody 负责「原生 Worktree + 多端会话实时查看 + 后续改代码」），强强互补。
- **兼容性**：完全不强制团队其他未使用 Lody 的成员安装 Lody——`Claude` / `Codex` / `Antigravity` 与 `Lody` 全部平等可选、按本机环境自动探测。
