# ADR-003 · 三大 AI CLI 统一适配器、只读沙箱与 JSON Schema 契约

- **状态**：已采纳（Accepted）
- **日期**：2026-11-26
- **关联需求**：[REQ-006](../../02-product/PRD.md#req-006--隔离-git-worktree-上下文准备p0), [REQ-007](../../02-product/PRD.md#req-007--三大-ai-cli-统一调度引擎p0), [REQ-008](../../02-product/PRD.md#req-008--安全防注入与权限隔离p0)

## 背景

应用需要同时支持 Claude Code (`claude`)、OpenAI Codex CLI (`codex`)、Google Antigravity CLI (`agy`)，并且执行输入来自他人创建的 GitHub PR 与评论，存在 Prompt Injection 风险。

## 备选方案

1. **直接调用各家 HTTP LLM API**：放弃本地 CLI 订阅额度，还失去各家 Agent 强大的代码库检索、工具调用与本地 `CLAUDE.md`/`AGENTS.md` 能力。
2. **让 CLI 直接自由输出 Markdown 并自己调 `gh pr review` 提交**：三家输出格式不统一，难以精准行级评论，且赋予外部 PR 触发的 AI 直接写 GitHub 的权限安全风险过高。
3. **统一 `ReviewAgentAdapter` + 隔离 Git Worktree + 强制只读沙箱 + 统一 JSON Schema**：由宿主程序掌控上下文准备、沙箱参数与最终 GitHub 写入。

## 决策

采纳 **方案 3**：
- 三家 CLI 统一实现 `ReviewAgentAdapter` 协议，均运行于宿主程序创建的独立 `git worktree add --detach` 目录中。
- 强制注入只读沙箱参数：
  - Claude Code: `--permission-mode plan --allowedTools "Read,Grep,Glob,Bash(git diff *),Bash(git log *),Bash(git show *)"`
  - Codex CLI: `codex exec --sandbox read-only`
  - Antigravity CLI: `agy -p --mode plan --sandbox`
- 统一使用 `--json-schema`（Claude / Agy）与 `--output-schema`（Codex）约束最终输出为标准 `ReviewResult` JSON，配合 `stream-json` / `--json` 实时解析进度。
- 环境变量不透传 GitHub 写 Token 给 AI 子进程，彻底杜绝 AI 绕过宿主擅自发评论。

## 影响与权衡

- **正面**：复用个人订阅、保留最强本地代码理解、统一渲染与回写逻辑、大幅降低 Prompt Injection 爆炸半径。
- **需注意**：三大 CLI 版本演进较快，需在 `ReviewDockCoreTests` 中覆盖命令构造单测，并在设置页提供版本检测与容错降级（若 Schema 校验失败可降级解析代码块 JSON）。
