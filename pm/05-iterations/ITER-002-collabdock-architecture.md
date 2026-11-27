# ITER-002 · 品牌升级为 CollabDock 与多平台可插拔架构重构

- **日期**：2026-11-26
- **里程碑**：M0 架构升级（在进入 M1 真实 GitHub 编码前完成顶层泛化，避免后期返工）
- **关联决策**：[ADR-005](../03-architecture/decisions/ADR-005-generalize-to-collabdock.md)
- **关联需求**：`REQ-003`, `REQ-004`, `REQ-005`, `REQ-007`, `REQ-008`, `REQ-009`, `REQ-013`

---

## 1. 背景与动因

在完成 M0 骨架与 `ITER-001` 视觉重设计后，进一步审视产品长期边界：**团队协作中 `@我` 触发本地 AI 的场景绝不仅限于 GitHub**（未来必然延伸至飞书群聊/文档、GitLab MR、Linear/Jira、Slack 或内部 Webhook）。与其写死 `ReviewDock` 后再大拆大改，不如在 M1 接入真实网络层前完成彻底的品牌与架构抽象。

---

## 2. 本次重构落地内容

1. **仓库与工程平滑迁移（保留完整 Git 历史）**：
   - 目录重命名为 `collabdock`，Target 升级为 `CollabDockCore` / `CollabDockApp` / `CollabDockCoreTests`，Bundle ID 更新为 `dev.collabdock.app`。
2. **四柱可插拔核心抽象 (`CollabDockCore`)**：
   - `CollaborationModels.swift`：引入 `PlatformKind`、`CollaborationItem`、`CollaborationPayload`（`.codeChange` / `.issueTicket` / `.conversation`）、`DeliveryMode`、`ExecutionOutput`（`.codeReview` / `.structuredReply`）。
   - `CollaborationConnector.swift`：定义 `CollaborationSource`、`CollaborationSink`、`CollaborationConnector` 与 `ConnectorCatalog` 能力协商表。
   - `Connectors/CodeHosting/DiffLineValidator.swift`：下沉为代码托管平台共享校验器（GitHub PR / GitLab MR 共用）。
   - `TriggerRuleEngine.swift` & `AppSettings.swift`：规则泛化为通用 `scopeAllowlist`/`scopeDenylist`（支持仓库通配符、频道前缀等），支持全局规则 + 连接器独立覆写，并增补多场景任务模板（代码审查 / 根因排查 / 协作答疑）。
   - `AgentCommandBuilder.swift`：根据载荷类型自动切换 `codeReviewJSONSchema` 与 `structuredReplyJSONSchema`，保持三端 CLI 只读沙箱与 `<untrusted_external_data>` 防注入边界。
3. **多平台自适应原生菜单栏 UI (`CollabDockApp`)**：
   - 状态栏图标升级为极简单色协作坞站符号 `square.stack.3d.up`。
   - 一级收件箱增加**多来源自动显隐过滤胶囊**（`全部 / GitHub / 飞书...`，单平台时自动隐藏），异构列表行根据载荷区分展示 Diff 绿红统计或平台标签。
   - 二级确认画布（`TaskDetailView`）自动按载荷切换元数据展示、推荐任务模板、合法交付方式与底部动态动词按钮（`用 Claude Opus 审查` vs `用 Claude Opus 分析`）。
   - 设置窗口首 Tab 升级为 **「协作来源（Connectors）」**，清晰呈现可插拔连接器状态与独立身份配置。
4. **单元测试扩展**：
   - 新增飞书群聊作用域通配符、Linear 工单指派开关、多载荷 Schema 切换、连接器能力协商等测试，全部通过。

---

## 3. 沉淀原则

- **强类型载荷联合 > 弱类型字典**：泛化架构绝不能以牺牲核心场景专业度为代价；Swift `enum CollaborationPayload` 既让列表、队列、确认流、三端调度完全复用，又让 GitHub PR 保留完整 Diff / Worktree / Pending Draft 深度能力。
- **抽象先行、落地聚焦**：架构支持 N 个连接器，但研发执行仍坚守「V1 只把 GitHub 打穿到极致」，防止战线拉长。
