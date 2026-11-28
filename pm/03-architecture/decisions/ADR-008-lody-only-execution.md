# ADR-008 · 执行方式暂时只保留 Lody

- **状态**：已采纳（Accepted）
- **日期**：2026-11-28
- **演进关系**：取代 `ADR-003`（三大 CLI 统一适配器与只读沙箱）、`ADR-004`（Pending Review 草稿回写）；修改 `ADR-006`（唤起策略只剩 Lody 后台会话）、`ADR-007`（Lody 从「四选一」变为唯一执行方式）
- **落地 PR**：#14（移除直连 CLI）、#16（提示词只发用户模板）

## 背景

直连 Claude Code / Codex / Antigravity CLI 的方式是「无头跑一次」：`claude -p`、`codex exec`、`agy -p` 跑完进程就退出，CollabDock 解析 JSON 结果再写成 GitHub Pending 草稿。实际使用中暴露出几个问题：

- **中途需要批准时没人能点**：三家在无头模式下都不会等人。Claude 和 agy 直接拒绝（agy 实测被拒后一个字都不输出），Codex 只按沙箱规则执行或失败。结果是审查可能不完整，而 CollabDock 看不到哪些操作被拒。
- **为了生成草稿，必须要求 AI 按固定 JSON 格式回答**，于是提示词里塞满系统附加内容；还要维护只读 / 权限模式、唤起方式、交付方式等一堆选项。
- **不是对话**：审完不能追问，复审只能重新跑一次。
- 用户日常用的是 Lody：自动发送、有完整对话界面、在界面里审批、进度和用量都看得到。而 Lody 本身就能把 Claude Code、Codex、Antigravity、Kimi Code、Grok 当作 agent 运行。

## 决策

1. **Lody 是唯一的执行方式。** 「选哪个模型 / 哪家」变成在 Lody 里选哪个 agent。
2. **移除只为直连 CLI 服务的全部代码**（git 历史保留）：
   - 直连后端、三家 CLI 的命令构造与输出解析、本机安装检测；
   - 托管运行与 JSON Schema、双模型会诊、行号校验；
   - CollabDock 写 GitHub 的交付路径（Pending 草稿 / 直接评论）与本地 Markdown 报告；
   - 只读 / 唤起方式 / 交付方式选项，以及只作用于交付文字的「审查语言」设置。
3. **发给 Lody 的内容只有用户模板**：分首次审查 / PR 更新后复审两个模板，渲染后加上可选的补充指令，不附加任何系统内容，也不夹带 PR 标题、描述、diff 等外部文字（#16）。
4. **兼容旧数据**：直连时代的设置、任务记录、用量记录照常加载；指向 claude / codex / agy 的计划改走 Lody；上一轮是直连引擎时开新的 Lody 会话，绝不往外来会话 ID 续聊；评论里的 `--engine` 提示忽略。

## 否掉的方案

| 方案 | 结论 | 否掉的原因 |
| :--- | :--- | :--- |
| CollabDock 内审批：后台常驻会话，审批请求做成卡片和带按钮的通知 | 技术上可行，三家都实测通过（见下文） | 要对接三套协议、管理进程生命周期，还要做对话界面，复杂度高 |
| 在终端里起交互式会话 | 可行 | 需要开终端窗口，CollabDock 看不到进度；用户不想要终端方式 |
| 用深链打开桌面客户端（Claude 桌面端 / Codex） | 可行 | 两家都只预填提示词、不会自动发送（有意的安全设计），和 Lody 比不够顺畅 |

## 以后重新接入时可用的实测结论

2026-11-27 在本机实测。版本：Claude Code 2.1.296、codex-cli 0.159.2、agy 1.5.16、Claude 桌面端 4.29.0、ChatGPT 桌面端 26.1111。

**把审批交给调用方（CollabDock）的方式**
- **Claude**：`claude -p --input-format stream-json --output-format stream-json --permission-prompt-tool stdio`。需要批准时在 stdout 发 `control_request`（`subtype: can_use_tool`），调用方回 `control_response`（allow / deny 加原因）后才继续。不加 `--permission-prompt-tool stdio` 时直接拒绝，结果里有 `permission_denials`。
- **agy**：`agy acp`（ACP 协议），需要批准时发 `session/request_permission`，选项为 `allow_once` / `reject_once`。`agy -p` 无头模式自动拒绝，结果里有 `denied_actions`，可能完全没有输出。
- **Codex**：`codex app-server`（JSON-RPC，标注实验性）。需要批准时发 `item/commandExecution/requestApproval`、`item/fileChange/requestApproval`，并实时推送 `thread/tokenUsage/updated`。`codex exec` 从不请求批准，只按沙箱规则执行。`codex agents` 浏览的是本机共享的 app-server 守护进程，桌面端能否看到由外部发起的对话尚未验证。

**后台会话**
- `claude --bg` 只能在信任过的目录启动，否则报 `Workspace not trusted`，所以不适合每次新建的临时 worktree；可以改用 `-w` 让 Claude 自己建 worktree。
- `claude agents --json` 能读到会话状态：busy / blocked / idle。

**桌面客户端深链（只预填，不自动发送）**
- Claude：`claude://code/new?q=<提示词>&folder=<目录>`、`claude://code/continue?session=<id>`、`claude://resume?session=<id>`（把 CLI 会话导入桌面端）。
- Codex：`codex://threads/new?prompt=<提示词>&path=<目录>`（或 `originUrl=<仓库地址>`，由客户端自己找本地项目）、`codex://threads/<id>?prompt=<提示词>`、`codex://code-review?pullRequest=<PR 链接>`。

**本地用量记录**
- Claude：`~/.claude/projects/<目录>/<会话 ID>.jsonl`，每条 assistant 消息带 `message.usage`。
- Codex：`~/.codex/sessions/<年>/<月>/<日>/rollout-*.jsonl`，有 `token_count` 事件。

## 影响与权衡

- **正面**：体验和 Lody 一致；净删约 5,400 行代码，确认卡片和设置大幅简化；CollabDock 不再往 GitHub 写任何东西，只读 GitHub。
- **负面**：使用前必须装 Lody，没有 Lody 的开源用户暂时无法派发审查；CollabDock 自动生成 Pending 草稿、双模型会诊、本地报告这些功能没有了。
- **以后**：重新接入其他执行方式时，新写一个 ADR 取代本条，不要回退到「无头跑一次」的旧模式。
