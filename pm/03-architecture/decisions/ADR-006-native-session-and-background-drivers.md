# ADR-006 · 本地 AI 唤起策略：原生持久会话与后台协议双驱动模型

- **状态**：已采纳（Accepted）
- **日期**：2026-11-26
- **演进关系**：深化 `ADR-003`（三端 CLI 调度适配器）
- **关联需求**：[REQ-007](../../02-product/PRD.md#req-007--三大-ai-cli-统一调度引擎p0), [REQ-010](../../02-product/PRD.md#req-010--一键终端接管与多模型会诊p1p2)

## 背景

如果仅仅把 `claude` / `codex` / `agy` 当作“跑完即焚”的一次性无头命令，用户看完摘要后如果想继续追问或顺手改代码，会产生上下文割裂。而三家产品各自的“定时任务 / 后台 Agent”之所以体验顺滑，本质在于：**后台静默创建一个原生持久会话（Native Session），落入各自的会话管理视图，并支持随时 `attach` / `resume` 无缝接管**。

## 调研实测（2026-11-26 本机验证）

1. **Claude Code**：原生支持 `claude --bg` 后台派发（落入 `claude agents --json`，可 `claude attach` / `claude logs` / `claude stop`）；且 `claude -p` 默认保留持久化 Session ID 供 `claude --resume` 接管。
2. **OpenAI Codex CLI**：`codex exec` 默认持久化会话（不传 `--ephemeral`）供 `codex resume` 与 Codex Desktop App 查看；另有 `[experimental]` 的 `codex app-server` 本地共享守护进程 JSON-RPC 2.0 协议。
3. **Google Antigravity CLI (`agy`)**：`agy -p` 持久化会话并产出 `conversationId` 供 `agy --resume`；另有官方标准 **`agy acp`**（Agent Client Protocol JSON-RPC 2.0 over stdio）。

## 决策

不修改各家 Desktop App 的私有定时任务配置（避免强耦合和无法获取结构化输出），而是在 `CollabDockCore` 抽象 **`ExecutionLaunchMode`** 与 **`AgentExecutionDriver` / `AgentDriverCatalog`**，支持双驱动演进：

1. **模式 A · 托管执行并生成草稿（`.managedStructuredRun`，默认）**：
   - 使用各家持久化无头模式（保留 Session/Conversation ID，禁止传 `--ephemeral`），通过 `stream-json` 实时流式展示进度、JSON Schema 严格约束输出并自动回写 GitHub Pending Draft，同时保存 `AgentSessionHandle` 供一键接管原会话。
2. **模式 B · 原生后台会话派发（`.nativeBackgroundSession`，类定时任务）**：
   - Claude Code 直接调用 `claude --bg` 落入 `claude agents` 后台队列，一键 `claude attach` 接管；
   - Codex / Antigravity 首版走持久化只读会话并留存句柄，M4 进一步接入 `codex app-server` 与 `agy acp` 协议驱动，解锁零冷启动与运行中插话（Steering）。

## 影响与权衡

- **正面**：兼顾「100% 可控的结构化回写（GitHub Pending Draft）」与「原生定时任务般的后台会话顺滑接管」。
- **安全红线不变**：无论选择哪种唤起模式，均强制经过本地人工确认，并默认注入只读沙箱参数。
