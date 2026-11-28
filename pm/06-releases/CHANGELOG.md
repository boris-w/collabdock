# Changelog

本项目变更日志遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与语义化版本规范，并与 `pm/` 编号体系联动。

## [Unreleased]

### Removed
- **移除系统提示词拼装与 `injectPresetPrompt` 开关** (`PR #16`)：不再向 Lody 附加系统安全约束段、`<untrusted_*>` 数据块、PR 标题/描述/评论/分支名/diff/提交记录、拉取对比命令或输出格式要求；移除 `AppSettings.injectPresetPrompt`（旧配置静默忽略）、`AgentCommandBuilder.buildSafePrompt` / `sanitizeUntrustedContent` 及确认卡片/设置页中的注入开关。
- **收拢为仅 Lody 执行路径，移除直连 CLI 引擎及相关托管/回写链路** (`PR #14`)：
  - 移除直连 Claude Code / Codex / Antigravity (`agy`) CLI 后端（`DirectCLIBackend`）、直连命令构建（含 `claude --bg` 与 `agy --resume`）、托管结构化运行（managed structured run）及 JSON Schema 输出。
  - 移除双模型会诊（`CouncilSynthesizer` / `CouncilPartner` / `ExecutionPlan.councilPartner`）。
  - 移除 CollabDock 侧 GitHub Pending Review 回写、行内评论校验与本地 Markdown 报告生成（`CollaborationSink`、`DeliveryContext`、`DeliveryMode`、`GitHubReviewFormatter`、`DiffLineValidator`、`GitHubConnector.deliver` / `fetchPullRequestDiff` 与打开本地报告操作）。
  - 移除独立「审查语言」（`ReviewLanguage`）、`agy` 模型发现（`fetchAgyModels` / `parseAgyModelsOutput`）以及 Claude / agy 结构化流式输出解析。
  - 移除菜单栏确认卡片与设置页中的 4 引擎卡片、模式（Mode）、交付方式（Delivery）、运行模式（Launch Mode）、会诊（Council）及审查语言控件，设置页「AI 引擎」精简为「Lody」。

### Changed
- **发给 Lody 的提示词改为纯用户模板（首次审查 / PR 更新后复审）+ PR 链接** (`PR #16`)：
  - 新增 `PromptTemplateKind`（`firstReview` / `followUp`）与 `TaskPreset.followUpPromptInstructions`、`defaultTemplate(for:language:)`、`effectiveTemplate(for:language:)`；模板字段留空或仅含空白时自动使用当前界面语言的内置默认模板（中/英 × 首次/复审），旧版默认文案 `请帮我 review 这个 PR。` 加载时平滑迁移为空并保留 `id` 与 `name`。
  - `AgentCommandBuilder.buildPrompt` 仅渲染经校验的有限占位符（`{{pr_url}}`、`{{repo}}`、`{{number}}`、`{{head_sha}}`、`{{previous_sha}}`，其余 `{{...}}` 原样保留），有补充指令时空一行接在末尾。
  - 「设置 → 提示词与团队」改为「首次审查 / PR 更新后复审」双输入框（灰色占位符展示当前语言内置默认并列出支持的占位符）；确认卡片「预览提示词」直接展示即将发给 Lody 的原文。
- **全链路默认并统一走 Lody 后台会话（兼容旧数据平滑反序列化）** (`PR #14`)：
  - `AgentEngine.selectableEngines` 收拢为 `[.lody]`，`ExecutionBackendKind` 仅保留 `.lody`，`ReviewExecutionService` 仅注入单个 Lody `backend` 且结果统一为 `.backgroundDispatched`；历史旧数据中的 `claude` / `codex` / `agy` 引擎记录、`managedStructuredRun`、`.codeReview` 输出、`localReportPath` / `deliveryURL`、旧版设置键与用量账本标签均保持平滑解码，非 Lody 上一轮复审记录自动降级为新开 Lody 增量会话。
  - 菜单栏确认卡片将 **Lody Agent**（来自 `lody agent-config list`，支持工作区默认或指定 Agent）提升为主选项，同时保留工作区目录、复审策略与附加指示控制；`TriggerRuleEngine` 忽略 `--engine`/`--cli` 对已移除直连引擎的指定并不再从 `--model` 反推引擎；`EnvironmentDetector` 仅探测 `git`、`gh` 与 `lody`。

### Fixed
- **修复手动导入 PR 新一轮时未自动归档上一轮已处理卡片的问题** (`REQ-002`)：`InboxSyncService` 抽出共用归档规则 `archiveSupersededRounds` 并新增 `importPullRequestResult` 返回被归档条目，`AppCoordinator.importPullRequest` 同步更新列表，使手动「+」导入与自动同步一致保持同 PR 仅一张活跃卡片。
- **修复 Lody 续聊复审及超 1 小时审查耗时丢失与累计上下文重复计入问题** (`REQ-014`)：
  - `LodySessionUsageSnapshot` 暴露 `lastMessageAt` 并新增 `roundDurationSeconds(since:)`（按最后一条消息时间减去本轮派发时间计算，移除 1 小时静默上限）；`AppCoordinator` 的卡片摘要与用量账本同步改用对应用量记录的 `createdAt` 作为本轮派发起点。
  - 统一 `syncPendingLodyUsage` 与实时监控回补逻辑：续聊同一 Lody 会话时用量账本仅计入相对同会话更早且已同步轮次的新增上下文（上下文发生压缩变小时记录当前上下文、不记负数），避免重复统计上一轮用量。
- **修复同提交 Re-request review 漏报与通知仅走邮件时漏检 `@mention`** (`REQ-002`, `REQ-010`)：
  - `PollRequest` 新增 `viewerLogin`（由 `InboxSyncService` 从 `currentHandle` 透传）；`GitHubConnector` 在 Notifications 与 Search 两条通道拉取 `review_requested` PR 时查询 `/issues/{number}/timeline`，当本人最近一次提交 review 之后存在发给本人的新 `review_requested` 事件时，将请求时间追加到 revisionKey（其余情况及拉取失败保持原有 `head.sha` 键，升级零重报）。
  - `GitHubConnector.evaluatePRAutoCompletion` 识别同提交第 N 轮复审卡片，避免把上一轮在同 SHA 上留下的 `CHANGES_REQUESTED` / `APPROVED` 旧结论套用到新卡片上。
  - `mentions:@me` 兜底搜索从仅 403 触发扩展为在 15 分钟 reconcile 周期同样执行（配合 `updated_at` 指纹跳过无变化 PR），解决 `/notifications` 返回 200 空列表（通知仅走邮件）时 `@mention` 从未被检出的问题。

### Changed
- **缩短无通知场景下的 Search 发现延迟并支持弹窗打开自动同步** (`REQ-002`)：`InboxSyncRequest` 新增 `reconcileIntervalSeconds`（默认从 15 分钟缩短为 3 分钟）；新增 `AppCoordinator.popoverDidOpen()`（接入 `MenuBarContentView.onAppear`），打开菜单栏弹窗时若距上次 Search 对齐超过 60 秒即自动触发带对齐的同步（遵守限流退避并保留 PR 状态对齐），无需手动点击刷新。
- **后台会话复审消息不再内嵌 Diff 正文并加固 ref 命令注入防护** (`REQ-008`, `REQ-010`, `REQ-014`)：派发到长生命周期后台会话（Lody / `claude --bg`）的第 N 轮复审（含续聊、新开增量会话与 force-push 回退）改为仅传递上一轮审查提交、最新提交、新增提交列表以及基于整数 PR 编号（`git fetch origin pull/<n>/head`）与校验后十六进制 SHA / 白名单基线 ref 的 `git diff` 指令，杜绝分支名命令注入并避免大段 diff 撑爆会话上下文；直连 CLI 托管运行（`agy` / `claude` / `codex`）继续保留内嵌 `<untrusted_incremental_diff>`。
- 测试：补齐环境探测、GitHub PR 导入与批量状态查询（含 GraphQL 注入防护）、回写时拉取 diff、Lody 目录缓存与模型默认值等用例，`CollabDockCore` 行覆盖率 77.7% → 85.9%，CI 门槛提高到 80%。
- 开源并改为 GitHub PR 迭代：`main` 受保护（PR + CI 必须通过、仅 squash 合并）；CI 新增 `make coverage`，要求 `CollabDockCore` 行覆盖率 ≥ 75% 并在 Job Summary 输出逐文件覆盖率；新增 `AGENTS.md` 约定 AI 开发会话的 PR / TDD / 隐私规则；`pm/04-planning` 冻结，待办迁移至 GitHub Issues。

### Added
- **英文一等界面语言与独立审查语言支持** (`issue #4`)：
  - 新增 `ResolvedLanguage`（`zhHans` / `en`）、`AppLanguage`（跟随系统 / 简体中文 / English，无匹配系统语言时回退英文）与 `ReviewLanguage`（跟随界面语言 / 简体中文 / English），持久化至 `AppSettings`（旧配置与未知字段值平滑回退默认值）。
  - `CollabDockCore` 与 `CollabDockApp` 各自提供完整 String Catalog（`Localizable.xcstrings`），全量覆盖界面文案、模型/模式/状态标签、错误提示与流式进度，并将 `Package.swift` `defaultLocalization` 与 `Info.plist` `CFBundleDevelopmentRegion` 设为 `en`（同时声明 `en` / `zh-Hans`）。
  - `GitHubReviewFormatter`、`CouncilSynthesizer`、`DeliveryContext` 与 `ReviewExecutionRequest` 支持按 `reviewLanguage` 输出 Pending Review 正文、行内评论严重度标签、本地 Markdown 报告及双模型会诊合并文案（兼容旧调用默认 `.zhHans`）。
  - 「设置 → 工作区」新增「界面语言」（写入 App 级 `AppleLanguages` 覆盖并提供「立即重启」）与「审查语言」选择器；`scripts/package-app.sh` 同步打包 SwiftPM 资源 bundle 与 `.lproj` 目录；离屏截图工具与 `README.en.md` 同步支持中英文双语截图。
- **同 PR 单卡片防重、上一轮自动归档与参与 Review 的 PR 免关键词 `@mention` 触发** (`REQ-002`, `REQ-003`)：
  - 新增 `TaskCompletionReason.superseded` 与 `InboxSyncResult.supersededItems`：新一轮复审卡片入箱时，同 PR 仍停留在收件箱中的已处理卡片（草稿就绪 / 失败）自动归档至「已完成」并保留历史审查结果（界面展示「已进入第 N 轮」），同时通过 `previousReview` 与新一轮关联。
  - 同一个 PR 在收件箱中已存在「待确认」卡片时，后续事件仅标记已见、不重复建卡也不重复通知；同一次同步内命中多个事件时只保留一张卡片且优先保留 `reviewRequested`。
  - `IncomingCollaborationEvent` 新增 `viewerIsReviewer: Bool = false`：`GitHubConnector` 结合 PR `requested_reviewers` 与 issue timeline 判定当前用户是否为该 PR 的 reviewer（仍在请求列表或曾提交过非 pending review），命中时放行不带关键词的直接 `@我`（自 @、机器人、仓库黑名单、关闭提及等保护不变）。
- **Codex 增量复审续聊上一轮会话** (`REQ-010`)：支持将上一轮 Codex 审查会话继续用于第 N 轮复审（`codex exec resume <SESSION_ID> <PROMPT>`），通过 `-c sandbox_mode="..."` 保持只读/所选沙箱策略并由隔离 worktree 作为进程工作目录，补齐 Claude Code / Antigravity / Lody / Codex 全引擎续聊闭环。
- **猫坞 PeekCat 品牌图标与 6 态原生菜单栏矢量重塑** (`ITER-018`, `REQ-004`, `REQ-011`, `TASK-016`)：
  - 完成两轮交互式可爱系图标评选（归档于 `pm/05-iterations/assets/ITER-018/`），定稿「V2 暖杏小黑猫配色 × 歪头招手猫造型」1024×1024 母版（`Resources/AppIconMaster.png`），并升级 `scripts/generate-icon.swift` 采用 SwiftUI 原厂 `.continuous` 连续曲率 Squircle 生成 `Resources/AppIcon.icns`。
  - 新增 `PeekCatMenuBarIcon.swift` 18×18pt `@2x` 单色 Template 矢量渲染器，全面取代通用 SF Symbols；全状态保留歪头招手猫轮廓锚点，区分 `空闲 / 待确认(+数字) / 执行中(+数字+2.5s 轻眨眼) / 草稿就绪(^ ^ 笑眼+提示点) / 已暂停(45% 半透明打盹) / 同步异常(! 徽章)`。
- **PR Approve / 合并 / 关闭自动归档闭环** (`ITER-017`, `REQ-002`, `REQ-010`)：
  - 新增单次批量 GraphQL 轻量状态对齐（收件箱空时零消耗，点开菜单栏或同步时按 25s 节流自动对齐）：你在 GitHub 提交 `APPROVED` 或 PR `MERGED` / `CLOSED` 后自动归档至「已完成」并区分显示 `已 Approve` / `已合并` / `已关闭`。
  - 提交 `CHANGES_REQUESTED` 的 PR 保留在收件箱并标示 `待修复` 继续跟进；严格防多轮复审历史 Approve 误杀；可在「设置 → 触发规则」随时开关。
- **全引擎执行模式（Mode）自由可选与按 Agent 记忆** (`ITER-016`, `REQ-007`, `REQ-014`)：
  - 实时解析 `lody agent-config list --json` 返回的 `runConfig.modes`（如 Antigravity 的 `Plan / Default / Accept edits / Auto`，Claude Code 的 `Plan / Manual / Accept edits / Auto / Bypass permissions`，Codex 的 `Read-only / Agent / Agent (auto review) / Agent (full access)`），并同步支持直连 Claude / Agy / Codex 模式选择。
  - 在「设置 → AI 引擎」与菜单栏确认卡片（`Agent / 模型 / 强度 / 模式` 四项完整齐备，含复审续聊）均开放模式下拉选择并自动记忆，真实透传 `--mode` / `--permission-mode` / `--sandbox`。
- **邮件式极简收件箱与隐藏开发者模式** (`ITER-015`, `REQ-002`, `REQ-003`)：
  - 菜单栏首页重构为 `收件箱 | 已完成` 邮件式管理：移除底部引擎胶囊条与 `只读沙箱` 文案，顶部收拢为 4 图标；待审草稿与失败条目留驻收件箱并支持 `✓ 标为完成`、`🗑 单条删除` 与 `清空已完成`（保留本地用量账本与去重记录）。
  - 新增隐藏「开发者模式」（`设置 → 工作区` 底部版本号连点 5 次或设置窗内按 `⌘⇧D` 触发），开启后可一键加载/清空收件箱演示任务与统计示例数据（纯内存隔离，关闭即清理）。
- **Review 用量与成本统计面板** (`ITER-014`, `REQ-007`, `REQ-010`, `REQ-014`)：
  - 新增本地 SQLite `review_usage_runs` 账本，自动采集 Claude Code / Antigravity (`agy`) / Codex CLI 精确 Token（输入/输出/缓存/思考）与耗时，并支持 Lody 会话完成后通过 `lody session show --json` 异步回补真实上下文用量与模型。
  - 新增菜单栏「用量速览」二级页与设置页第 6 个 Tab「用量统计」（内置原生 `Swift Charts` 每日堆叠趋势图、按模型横向分布、活跃仓库 Top 3、审查明细流水、一键复制 CSV，以及 `USD ($)` / `CNY (¥)` 币种随时切换）。
- **重复审查闭环：增量 Commit Diff 与原会话续聊** (`ITER-013`, `TASK-015`, `REQ-010`, `REQ-014`)：
  - 修复 GitHub `review_requested` 通知误用旧评论 ID 去重的边界 Bug（改按 `pr.head.sha` 去重，推新代码再点 Re-request 必秒触发）。
  - 自动识别同 PR 历史审查记录，收件箱标示「第 N 轮复审」，确认卡片新增「复审策略」菜单（续聊原会话增量 Diff / 新开会话增量 Diff / 新开全量 PR）。
  - 计算 `上次SHA..最新SHA` 真实增量 Commit 日志与 Diff（检测到 rebase / force-push 自动回退全量并提示）；支持通过官方 `lody session chat` 续聊原 Lody 会话，或对 Claude / Antigravity 自动附带 `--resume`。
- **仓库目录映射可视化与 Worktree/主目录按需切换** (`ITER-012`, `REQ-006`, `REQ-014`)：设置页「工作区」实时列出自动发现的 `owner/repo → 本地目录` 映射，支持多副本一键切换（如 `backend` / `backend-2`）与原生目录选择器固定；菜单栏确认卡片新增「项目目录」行，默认独立 Git Worktree，可单次切换主目录或临时换目录。

### Fixed & Improved
- **GitHub 账号展示升级为头像 + 别名 + Handle** (`ITER-016`, `REQ-001`)：通过 `gh api user` 实时采集 GitHub 昵称（`name`）与头像（`avatar_url`），在内存缓存 `NSImage` 消除菜单栏弹窗闪烁，并在收件箱底栏与「设置 → 协作来源」同步展示圆形头像、在线状态角标与别名 + `@handle`。
- **Lody 会话精简标题与实时审查状态追踪** (`ITER-015`, `REQ-014`)：
  - Lody 侧边栏会话标题去冗余改为 `CR #编号 PR标题`（归属本地项目下不再重复显示 `[CollabDock] owner/repo`）；卡片顶部去掉多余 `GitHub · ` 前缀并中间省略，完整露出 PR 编号。
  - 新增 Lody 后台会话实时轮询追踪（`lody session show --json`）：卡片动态展示 `审查中（含实时上下文 Token） → 审查完成（含耗时与 Token） / 执行异常`，同步联动菜单栏运行状态、推送完成通知并自动回补本地 SQLite 用量账本。
- **修复 CLI 异常退出报错空白（吞掉 stdout JSON error）并加固 Lody 认证与 Fork PR 分支刷新** (`ITER-015`, `REQ-014`)：
  - `AgentSessionRunner.extractFailureMessage` 优先从 stdout/stderr 提取 JSON `error`/`message` 字段（彻底解决 `lody --json` 失败时 `stderr` 为空导致只显示 `code 1：` 空白提示的 Bug），并在检测到 Lody CLI Token 过期时直接引导运行 `npx lody login`。
  - `npx` 回退统一钉住 `lody@latest`，彻底杜绝复用本机 `~/.npm/_npx` 中陈旧的 `next`（staging）预发布缓存导致生产 Token 被误拒。
  - 剥离从宿主会话继承的 `LODY_*` / `ELECTRON_RUN_AS_NODE` 环境变量；`WorktreeManager.refreshRemoteRefs` 增加跨 Fork PR `refs/pull/<num>/head` 拉取回退。
- **修复 Lody 偶发「未找到可执行文件：lody」Bug** (`ITER-014`, `REQ-014`)：
  - 统一 `AgentSessionRunner.resolveExecutionBinary` 与 `AgentCommandBuilder` 的 Lody 可执行文件解析：优先全局 `lody`，缺失时无感自动回退至 `npx -y lody`（修复设置中关闭回退开关导致探测绿灯但执行报错的自相矛盾，以及冷启动环境探测未完成前立即发起审查的竞态问题）；移除设置页易误触的 `npx` 回退开关，并在 `confirmAndRun` 补齐冷启动按需环境探测。
- **AI 引擎设置页去耦合与文案消歧** (`ITER-012`, `REQ-007`, `REQ-014`)：`Lody.ai 工作区编排设置` 改为仅在默认引擎选中 `Lody` 时动态展示，移除了与「工作区」页重复的 Worktree 开关，并将目录来源标签改写为「源自 Lody」且标注全引擎共用。
- **精简预制任务模板与轻量化提示词** (`ITER-011`, `REQ-005`, `REQ-011`)：默认预制从 6 条精简为 1 条极简模板「Review 这个 PR（`请帮我 review 这个 PR。`）」，未修改过旧出厂模板的配置自动平滑精简，设置页支持按需新建与单条删除并明确标注「仅注入当前选中的 1 条」。
- **真实 PR 端到端验收与 5 处真实环境问题修复** (`ITER-010`, `TASK-014`, `REQ-006`, `REQ-007`, `REQ-014`)：
  - 新增 `lody project list --json` / `lody github list --json` 探测与三层智能工作区路由（优先命中 Lody 本地项目 `--local-project --worktree --branch` -> 云端已绑 `--repo` -> CollabDock 隔离 Worktree 路径），彻底解决未在 Lody 云端绑定 GitHub 仓库时 `--repo` 失败的问题，并为派发会话自动注入可读 `--title`。
  - 修复在同名 Node 项目目录（如 `Lody` 仓库本身）调用 `npx -y lody` 被本地 `package.json` 劫持的 Bug；修复 `WorktreeManager` `origin/<baseRef>` 拉取 refspec 与自动合并 Lody 本地项目仓库路径。
  - 修复 `agy` 当模型 ID 已编码强度后缀（如 `gemini-3.8-flash-high`）时与 `--effort` 冲突的问题；修复 `AgentStreamParser` 解析 `agy` 嵌套 `result.response` / `step_update.tool_name`；并在非后台托管模式直接安全内嵌 `<untrusted_pr_diff>` 供只读文件工具审查，避免无头沙箱因 Bash 拦截返回空响应。
  - 菜单栏收件箱新增 `+` 快捷导入栏，支持粘贴任意 GitHub PR 链接或 `owner/repo#编号` 立即进入确认与审查流程。
- **Lody 真实模型探测与 Agent/Model 两级联动** (`ITER-009`, `REQ-014`, `ADR-007`)：
  - 新增 `lody workspace list --json` / `lody agent-config list --json` 异步目录探测与本地缓存（`lody-catalog-cache.json`），实时拉取用户 Lody 工作区内的真实 Workspace、Agent Config 与模型列表（如 Antigravity / Claude Code / Codex 各自全部可用模型）。
  - 解耦 `ExecutionPlan.lodyAgentConfig` 与 `plan.model`，修复设置页「无模型可选」与「Agent Config 重复不同步」问题，并在菜单栏确认卡片同步支持 Lody Agent + 模型两级联动与分 Agent 记忆默认模型。
  - 修复非交互子进程 `npx` 缺 `-y` 的潜在失败问题，并通过官方 `lody session create` 参数透传 `--agent-config`、`--model`、`--mode`（`plan`/`read-only`）与 `--config-option` 思考强度。
- **设置页表单 Bug、下拉选型与提示词透明化** (`ITER-008`, `REQ-005`, `REQ-011`, `REQ-014`)：
  - 修复 macOS grouped Form 空输入框无边框/无占位符的隐形 Bug，并实现 `AppSettings` 向后兼容 JSON 解码（升级不丢旧配置）。
  - 补齐「默认模型」联动下拉选择，并将 Lody「默认 Agent Config」改为原生下拉选择（保留自定义选项）。
  - 修复 Lody / 原生后台会话误注入 JSON Schema 约束的问题（自动改输出人类可读 Markdown）；开放提示词注入总开关、设置页内联编辑任务模板，以及确认画布「预览提示词」。

### Added
- **M4 团队分发套件与多模型会诊** (`ITER-007`, `TASK-016`, `TASK-017`, `REQ-010`, `REQ-011`)：
  - 新增 `CouncilSynthesizer` 与折叠式双模型会诊 UI：支持在同一隔离只读 Worktree 内并行跑 2 个引擎/模型，交叉识别 `±3` 行共识问题并自动提权。
  - 新增原生 macOS 图标生成器 `scripts/generate-icon.swift` 与 `Resources/AppIcon.icns`，升级 `package-app.sh` 支持 Universal Binary（`UNIVERSAL=1`），新增 `scripts/package-dmg.sh`（`make dmg`）、Homebrew Cask 模板 `packaging/homebrew/Casks/collabdock.rb` 与设置页团队配置包一键导入导出。
- **M2/M3 端到端全链路闭环** (`ITER-005`, `TASK-010..013`, `TASK-015`)：
  - 新增 `RepoScanner` 与 `WorktreeManager`：自动映射本地 Git 仓库或按需浅克隆，在隔离 detached worktree 中只读审查并计算 Diff，零污染当前开发分支。
  - 新增 `AgentStreamParser` 与 `AgentSessionRunner`：打通 `claude` / `codex` / `agy` / `lody` 真实流式子进程、强制剥离 GitHub 写 Token 环境变量、支持菜单栏实时中止与双驱动唤起。
  - 新增 `GitHubReviewFormatter` 并完成 `GitHubConnector.deliver`：自动落盘本地 Markdown 报告、按 Diff Hunk 校验行号（越界自动降级 Summary）、默认提交仅本人可见的 GitHub Pending Review 草稿并支持 `suggestion` 代码块。
  - 新增 `SystemIntegrationService`：集成 macOS 原生 `UNUserNotificationCenter` 通知点击直达、`SMAppService` 开机自启、本地报告打开与一键接管原会话（Lody Deep Link / Terminal `attach`/`--resume`）。
- **Lody.ai 一等集成** (`ITER-004`, `ADR-007`, `REQ-014`, `TASK-020`)：新增 `Lody (lody.ai)` 执行与会话编排目标，支持本机 `lody` / `Lody.app` / `npx lody` 探测、`lody session create --json` 命令构造、`lody://session/<id>` Deep Link 与四引擎原生确认界面。
- **M1 核心引擎闭环** (`ITER-003`, `ADR-006`, `TASK-004..009`)：
  - 新增 `EnvironmentDetector`：补全 GUI `PATH`，实时探测本机 `git`/`gh`/`claude`/`codex`/`agy` 版本与路径、自动解析 `gh auth status` 账号与权限范围，并动态拉取 `agy models` 列表。
  - 新增 `GitHubConnector`：实现 `GET /notifications` 304 零配额条件轮询（`If-Modified-Since` + `X-Poll-Interval`），并在缺少 `notifications` scope 时自动降级至 Search API（`review-requested:@me` + `mentions:@me`）。
  - 新增 `SQLiteTaskStore`（macOS 内置 SQLite3 WAL）与 `SettingsStore`（配置自动落盘 + 团队配置包 JSON 导出）。
  - 新增 `AgentExecutionDriver` / `ExecutionLaunchMode` 双驱动抽象（`ADR-006`），支持托管持久化执行与原生后台会话派发（如 `claude --bg`）。
- **M0 立项与项目管理体系** (`TASK-001`)：建立 `pm/` 六阶段可追溯软件开发目录（调研、PRD、UX 规范、架构与 ADR-001~006、Roadmap/Backlog/追溯矩阵、迭代日志与团队分发 SOP）。
- **核心引擎首批可测模块** (`TASK-002`, `TASK-003`)：`TriggerRuleEngine`、`AgentCommandBuilder`、`DiffLineValidator` 及 `.app` 打包脚本。

### Changed
- **GitHub 零配额 304 快速通道与限流退避** (`ITER-006`, `REQ-002`, `ADR-002`)：304 响应跳过常规 Search（仅 15 分钟低频对齐）、新增 PR `updated_at` 指纹缓存跳过重复水合、缺 `notifications` scope 时自动免撞 403 并降频至 180s、解析 `X-RateLimit-*` 与 `Retry-After` 自动退避并在设置页实时展示剩余配额。
- **品牌升级为 CollabDock 与四柱可插拔架构重构** (`ITER-002`, `ADR-005`, `REQ-013`)：迁移至 `CollabDock`（`CollabDockCore` / `CollabDockApp`），抽象 `CollaborationConnector`、强类型 `CollaborationPayload`、通用作用域规则与双模态 Schema。
- **菜单栏 UI 全面重设计** (`ITER-001`, `REQ-004`, `REQ-005`)：对标 CodexBar / Magpie / Linear / macOS Tahoe Liquid Glass，引入 `DesignSystem.swift`、自适应收件箱、Control Center 二级推入确认画布、三宫格引擎瓷砖、无框单箭头参数菜单、黑白高对比主 CTA 与 DEBUG 离屏视觉快照工具。
