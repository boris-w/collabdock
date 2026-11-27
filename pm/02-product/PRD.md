# 02 · 产品需求规格说明书（PRD）

> **文档状态**：v0.2（`ITER-002` / `ADR-005` 升级为多平台通用协作调度坞站 CollabDock）  
> **最后更新**：2026-11-26  
> **关联文档**：[UX_SPEC.md](./UX_SPEC.md) | [ARCHITECTURE.md](../03-architecture/ARCHITECTURE.md) | [ADR-005](../03-architecture/decisions/ADR-005-generalize-to-collabdock.md) | [TRACEABILITY.md](../04-planning/TRACEABILITY.md)

---

## 1. 产品定位与目标用户

- **一句话定位**：运行在 macOS 菜单栏的**多平台本地 AI 协作调度坞站（CollabDock）**——以可插拔连接器汇聚 GitHub（V1 完整闭环）及未来 GitLab / 飞书 / Slack / Linear / Jira 中 `@你` 或指派给你的协作任务，由你在本地手动确认并选定本地 AI 引擎与模型后，在只读隔离环境中安全执行并回写草稿或回复。
- **目标用户**：
  - 使用 macOS 进行日常开发，且本机安装了 `claude`、`codex` 或 `agy`（任意一款或多款）的研发工程师。
  - 希望在团队内统一推广安全、可控、低成本的本地 AI 协作与代码审查工作流的研发团队。

---

## 2. 核心需求列表（Requirements）

优先级说明：`P0` = 首版可用闭环必选，`P1` = 团队推广核心增强，`P2` = 差异化高阶体验。

### REQ-001 · GitHub 认证与本地运行环境体检（P0）
- **描述**：应用启动与设置页需自动检测本机依赖状态，降低团队成员首次上手门槛。
- **详细要求**：
  1. 优先复用本机 `gh auth token` 与当前登录 GitHub 用户名（支持自定义 `gh` 二进制路径）；同时允许在 Keychain 中手工录入 GitHub Personal Access Token（PAT）作为备选。
  2. 自动扫描并探测 `git`、`gh`、`claude`、`codex`、`agy` 是否安装、路径位置及版本状态（兼容 macOS GUI App `PATH` 缺失 `/opt/homebrew/bin`、`/usr/local/bin`、`~/.local/bin` 的问题）。
  3. 缺失项给出清晰的可复制修复提示。
- **验收标准**：未安装某一款 CLI 时仅将该引擎置灰禁用，不影响其他已安装 CLI 正常使用；能正确解析当前 GitHub 登录账号名。

### REQ-002 · GitHub PR 事件监听与增量拉取（P0）
- **描述**：后台持续、低开销地发现需要用户关注的 PR Review 请求。
- **详细要求**：
  1. 使用 `GET /notifications` 配合 `If-Modified-Since` 与 `X-Poll-Interval` 做条件轮询；`304 Not Modified` 不计配额。
  2. 支持按配置的同步间隔（默认遵循服务端 `X-Poll-Interval`，最低 60 秒）和手动点击「立即刷新」。
  3. 对命中的 PR 线程二次拉取 PR 详情（标题、作者、分支、base/head SHA、增删行数、文件数、是否 Draft）及触发评论正文。
  4. 辅以待审 PR 查询（`review-requested:@me`）对齐直接指派且通知已读的场景。
  5. 本地 SQLite 持久化记录 `(repo, pr_number, trigger_key)` 去重，支持电脑休眠唤醒后自动补拉。
- **验收标准**：断网/休眠期间产生的新 `@mention` 或 `review_requested`，恢复联网后 1 个轮询周期内进入队列且不重复提醒。

### REQ-003 · 可手动配置的触发规则引擎（P0）
- **描述**：用户可精细控制「哪些事件会弹出来打扰我」，避免噪音。
- **详细要求**：
  1. **事件来源独立开关**：
     - 开关 A：PR 评论中 `@我`（`mention`）。
     - 开关 B：GitHub `Request Review` 指派给我（`review_requested`）。
     - 开关 C（默认关）：团队指派（`team_mention` / team review request）。
  2. **关键词过滤（作用于 `@mention`）**：
     - 可配置“必须包含关键词才触发”（默认开启，预设：`review`、`cr`、`帮忙看`、`请看`、`check`，支持用户增删）或“PR 中任意 `@我` 均触发”。
  3. **范围与降噪规则**：
     - 仓库白名单 / 黑名单（支持 `owner/*` 通配符）。
     - 忽略自己发出的评论（强制开启，防自循环）。
     - 可选开关：忽略 Draft PR、忽略 Bot 账号触发。
  4. **可选评论意图解析**：解析评论中附带的建议参数（如 `--model opus`、`--focus security`），仅作确认卡片的**预填建议**，不绕过人工确认。
- **验收标准**：给定一组模拟 GitHub 通知与评论，规则引擎的命中/过滤结果 100% 符合用户勾选配置，并有完整单元测试覆盖。

### REQ-004 · macOS 原生菜单栏常驻与通知提醒（P0）
- **描述**：以最小视觉打扰常驻 macOS 顶部菜单栏，并在有新待审 PR 时及时触达。
- **详细要求**：
  1. 纯菜单栏 App（`LSUIElement = true`，不占 Dock 图标），状态栏展示图标 + 待确认/运行中数量角标。
  2. 新任务入队时发送 macOS 原生通知（`UNUserNotificationCenter`），显示仓库、PR 标题、触发者与触发方式；点击通知打开菜单栏面板并定位到该任务。
  3. 支持「开机自启」（`SMAppService.mainApp`）与「勿扰/暂停监听」一键切换。
  4. 维护清晰的任务状态机：`pendingConfirmation` -> `preparing` -> `running` -> `draftReady` / `completed` / `failed` / `dismissed`。
- **验收标准**：后台收到新事件 2 秒内更新菜单栏角标并弹出原生通知；点击通知可直接展开对应卡片。

### REQ-005 · 人工确认门控与动态模型选择（P0）
- **描述**：任何本地 AI 执行之前，必须经由用户在本地界面确认并选定工具与模型。
- **详细要求**：
  1. 确认卡片展示：仓库/PR 编号、标题、作者、Diff 统计（`+X / -Y, N files`）、触发来源标签（`@mention` 或 `Request Review`）与触发评论原文。
  2. 执行参数选择器：
     - **AI 引擎**：`Claude Code` / `Codex CLI` / `Antigravity (agy)`（自动高亮可用项）。
     - **模型选择**：按所选引擎动态列出可用模型（`agy` 支持从 `agy models` 动态刷新；Claude/Codex 结合内置列表与用户自定义模型）。
     - **思考强度（Effort）**：`low` / `medium` / `high` / `xhigh` / `max`（按引擎能力映射）。
     - **Review 预设模板**：通用审查 / 安全审计 / 架构与性能 / 仅查 Bug / 自定义补充指令。
     - **结果交付模式**：`GitHub Pending Review 草稿（默认）` / `仅本地查看` / `直接发表 Comment`。
  3. 明确操作按钮：`确认执行`、`忽略`、`浏览器打开 PR`。
- **验收标准**：未经用户点击「确认执行」，绝不会拉起任何 CLI 子进程；切换引擎时模型下拉框实时联动更新，并记住用户上次偏好或按仓库默认策略预填。

### REQ-006 · 隔离 Git Worktree 上下文准备（P0）
- **描述**：在完全不干扰用户日常开发分支的前提下，为本地 AI 准备完整 PR 代码上下文。
- **详细要求**：
  1. 支持配置本地代码搜索根目录（如 `~/work`、`~/projects`），自动扫描 `.git/config` 匹配 `owner/repo`；支持手动绑定路径。
  2. 若本机尚无该仓库，支持自动浅克隆（`git clone --filter=blob:none`）至应用缓存目录。
  3. 拉取目标 PR head ref 并使用 `git worktree add --detach` 创建独立隔离目录运行 AI；任务结束后按策略自动清理或保留供接管。
- **验收标准**：执行 Review 期间，用户原仓库目录的当前分支、`git status` 与未暂存修改保持 100% 不变；支持同时并行执行 2 个不同 PR 的 Review。

### REQ-007 · 三大 AI CLI 统一调度引擎（P0）
- **描述**：屏蔽三家 CLI 的参数和输出差异，实现统一执行、实时流式进度展示与结构化结果解析。
- **详细要求**：
  1. 抽象 `ReviewAgentAdapter` 协议，提供 `ClaudeCodeAdapter`、`CodexCLIAdapter`、`AntigravityCLIAdapter` 三套实现。
  2. 解析三家的流式 JSON 输出（`stream-json` / `--json`），在界面实时显示当前状态（分析中、阅读文件、生成结论、耗时）与可随时「中止任务」按钮。
  3. 通过统一 JSON Schema 约束输出结构（`summary`、`recommendedVerdict`、`comments[]`）。
  4. 记录 CLI 会话 ID（Session/Conversation ID）用于后续终端接管。
- **验收标准**：任选三家之一执行同一 PR，均可产出符合统一 `ReviewResult` 模型的数据结构，并支持运行中安全取消进程树。

### REQ-008 · 安全防注入与权限隔离（P0）
- **描述**：消除“外部 PR 内容触发本地 AI”的安全隐患。
- **详细要求**：
  1. 三层防护：人工确认启动 + CLI 只读沙箱参数强制注入 + Prompt 中明确隔离 `<untrusted_pr_data>`。
  2. AI 子进程**无权直接调用 `gh` 写入 GitHub**，写操作完全由宿主 Swift 代码经结构校验后执行。
  3. 确认卡片上明确标识外部贡献者/非白名单作者风险提示。
- **验收标准**：CLI 启动参数单元测试断言必须携带只读沙箱标志；即使 PR 评论包含恶意修改文件指令，沙箱也阻止写入。

### REQ-009 · GitHub Pending Review 草稿回写与行号校验（P0）
- **描述**：把结构化 Review 结果高可靠地落到 GitHub PR 上，同时保护用户声誉。
- **详细要求**：
  1. 解析 PR Diff 计算每个文件的有效可评论行号集合（Diff Hunk Valid Lines）。
  2. 有效行号内的评论作为精准 Inline Comment 提交，含代码建议时自动包装为 GitHub ```` ```suggestion ```` 块；越界行号自动归拢到顶层 Summary 中，避免 `422` 提交失败。
  3. 默认调用 `POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews` 且**不传 `event`**，生成仅本人可见的 **Pending Review 草稿**，并在结果页提供一键直达浏览器审核的按钮。
  4. 支持将本次 Review 报告导出/保存在本地 Markdown 历史记录中。
- **验收标准**：含合法行号与越界行号混合的模拟 Review JSON，能正确拆分且调用 GitHub API 成功生成 Pending Draft。

### REQ-010 · 一键终端接管与多模型会诊（P1/P2）
- **描述**：发挥本地多 CLI 独特优势的进阶工作流。
- **详细要求**：
  1. **终端接管（P1）**：Review 完成后支持一键打开 Terminal / iTerm2 / Ghostty，在对应 Worktree 目录执行 `claude --resume` / `codex resume` / `agy --resume` 继续深挖。
  2. **增量复审（P1）**：同一 PR 有新 Push 时支持仅针对 `lastReviewedSHA...newHeadSHA` 做增量审查。
  3. **多模型会诊（P2）**：确认卡片允许同时勾选 2 个引擎/模型并行审同一 PR，结果页标出「共识问题」与「独立发现」。

### REQ-011 · 团队分发、团队模板与自动更新（P1）
- **描述**：满足给团队成员稳定分发与统一规范的需求。
- **详细要求**：
  1. 提供可重复构建的 `.app` 与 `.dmg` 打包脚本，支持 Apple Developer ID 签名与 Notarization 公证（无证书时支持 Ad-hoc 本地试跑说明）。
  2. 提供 Homebrew Cask Formula 模板与 GitHub Releases 分发流水线，以及 Sparkle Appcast 自动更新集成方案。
  3. 支持导入/导出 **团队共享配置包（JSON）**：预置团队仓库白名单、触发关键词、团队 Review Prompt 规范，导入时不覆盖个人模型偏好与本地目录。

### REQ-012 · 三家 CLI 原生插件联动包（P2）
- **描述**：为长期停留于终端 CLI 内的开发者提供会话内入口。
- **详细要求**：
  1. 提供共享的 Review/Triage Skill 与连接本地 SQLite 队列的轻量 MCP Server，打包为 Claude Code / Codex / Antigravity 原生插件。
  2. 支持在活跃对话中通过 `/collab-inbox` 浏览并认领同一个待处理任务队列。

### REQ-013 · 多平台可插拔协作连接器架构（P0 架构 / P1 扩展）
- **描述**：避免系统锁死在 GitHub 单平台，为团队后续接入更多协作工具提供统一扩展契约（关联 `ADR-005`）。
- **详细要求**：
  1. 核心领域抽象为 `PlatformKind`、`CollaborationItem`、`CollaborationPayload`（`.codeChange` / `.issueTicket` / `.conversation`）、`CollaborationSource` 与 `CollaborationSink`。
  2. V1 完整打通 **GitHub Connector**（PR Review 闭环），架构与 UI 原生支持按来源过滤、按载荷切换任务模板与合法交付模式。
  3. 后续按需热插拔扩展 **GitLab MR / 飞书群聊与文档 / Slack Thread / Linear / Jira / 自定义 Webhook** 连接器，无需重写确认流、规则引擎或本地 AI 适配器。

### REQ-014 · Lody.ai 本地工作区与会话编排深度集成（P1）
- **描述**：支持本地已使用 `lody.ai` 的开发者直接把确认后的协作任务派发为 Lody 原生会话（关联 `ADR-007`）。
- **详细要求**：
  1. `AgentEngine` 内置 `Lody (lody.ai)` 为一等执行/编排目标，支持配置目标 Workspace、默认 `agent-config`、`npx lody` 回退与 Lody 原生 Worktree。
  2. 自动探测本机 `lody` CLI、`/Applications/Lody.app` 与 `npx` 可用性。
  3. 通过官方 `lody session create --json` 派发会话，并支持通过 `lody://session/<sessionId>?workspace=<workspaceId>` Deep Link 一键跳转至 Lody Desktop 查看与接管。

---

## 3. 明确的非目标（Out of Scope for V1）

- ❌ 不做全自动无人值守自动发 Review（违背安全与人工确认初衷）。
- ❌ V1 不做 Windows / Linux 桌面端（专注原生 macOS SwiftUI 极致体验，但核心层 `CollabDockCore` 保持 Swift 纯逻辑解耦）。
- ❌ V1 不依赖任何自建云端服务器（保持零基础设施成本，Webhook 云中继作为后续可选能力）。
- ❌ 不替用户自动 Merge PR 或自动修改他人 PR 代码推送远端。
