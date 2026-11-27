# ADR-005 · 品牌与架构泛化：从 ReviewDock 升级为多平台协作调度坞站 CollabDock

- **状态**：已采纳（Accepted）
- **日期**：2026-11-26
- **演进关系**：扩展并泛化 `ADR-002`（事件接入层）与 `ADR-004`（平台交付与分发层）
- **关联需求**：[REQ-001](../../02-product/PRD.md) ~ [REQ-013](../../02-product/PRD.md)

## 背景

首版方案命名为 `ReviewDock`，领域模型（`ReviewTask`、`ReviewResult`、`repoAllowlist`）与界面文案均与「GitHub PR Code Review」深度耦合。但在团队真实研发协作中，「外部有人 `@我` 或指派我 -> 我在本地选 AI 引擎与模型确认后执行 -> 生成草稿/回复」这一范式天然不仅限于 GitHub：
- 代码托管：GitHub PR / Issue、GitLab MR
- 即时协作与文档：飞书（Lark）群聊/文档 `@我` 排查线上问题或评审方案、Slack Thread
- 项目与工单：Linear / Jira 指派分析根因

如果在 M1 写业务代码前不把连接器边界抽干净，后续接入第二个平台将面临大面积返工。

## 备选方案

1. **继续做 GitHub PR 专属工具，未来需要别的平台再另开项目**：启动略快，但团队桌面要装一堆碎片化菜单栏 App，三端 CLI 调度、安全沙箱与人工确认流被迫重复建设。
2. **过度抽象为无类型通用脚本平台**：丢掉 GitHub PR 的核心高价值特性（如 Diff 行号校验、Pending Review 草稿、隔离 `git worktree`），体验变平庸。
3. **四柱可插拔架构 + 强类型载荷联合（`CollabDock`）**：
   - 顶层统一为 `CollaborationItem`，但用强类型 Swift 枚举 `CollaborationPayload`（`.codeChange` / `.issueTicket` / `.conversation`）保留每个场景的专业深度。
   - 抽象 `CollaborationConnector`（`CollaborationSource` + `CollaborationSink` + `ConnectorCapabilities`），由 `ConnectorCatalog` 声明各平台能力。
   - **研发节奏保持克制聚焦**：V1 仍集中全部火力把 **GitHub Connector（PR Review 完整闭环）** 打穿到极致，其他连接器按里程碑热插拔加入。

## 决策

采纳 **方案 3**，将产品正式更名为 **CollabDock（协作 Dock）**（Bundle ID：`dev.collabdock.app`，Target：`CollabDockCore` / `CollabDockApp`）：
1. **事件接入与回写统一抽象**：`CollaborationSource` 负责拉取/监听外部协作事件，`CollaborationSink` 负责按平台原生能力交付（GitHub/GitLab 支持 `platformDraft` Pending 草稿；飞书/Slack/Linear 默认 `localDraftOnly` 或 `directReply`）。
2. **触发规则泛化**：`repoAllowlist`/`repoDenylist` 升级为通用 `scopeAllowlist`/`scopeDenylist`（兼容仓库 `org/*`、群名 `#oncall*`、Team Key），并支持全局规则 + 连接器独立覆写。
3. **输出与 Prompt 双契约**：`AgentCommandBuilder` 按 `CollaborationPayload` 自动切换结构化 Schema（代码变更走 `codeReviewJSONSchema`，工单/群聊走 `structuredReplyJSONSchema`），保持同一套三端 CLI 只读沙箱调度与 `<untrusted_external_data>` 防注入边界。
4. **菜单栏 UI 自适应**：多来源存在时自动呈现顶部平台过滤胶囊，单来源时保持零噪音极简；二级钻取页按载荷自动适配 Diff 统计、关联仓库、任务模板与交付模式。

## 影响与权衡

- **正面**：在不牺牲 GitHub PR Review 任何专业深度的前提下，为飞书、GitLab、Slack、Linear 铺平零返工扩展路径；产品定位与 `PortDock` 同家族高度一致。
- **纪律约束**：严禁因为架构泛化而在 V1 分散精力同时做 5 个平台——M1~M3 依然严格聚焦 **GitHub Connector 端到端闭环**，M4/M5 再逐个接入第二个连接器。
