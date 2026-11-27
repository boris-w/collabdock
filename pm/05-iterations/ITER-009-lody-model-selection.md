# ITER-009：Lody 真实模型列表探测、Agent/Model 解耦与 `npx -y` 加固

- **关联编号**：`REQ-014`、`ADR-007`、`TASK-020`
- **日期**：2026-11-26
- **状态**：已完成（34 项单测全绿，`build/CollabDock.app` 已重建并视觉验收）

---

## 1. 问题来源（用户实测截图反馈）

在 `Settings → AI 引擎` 中选中 `Lody (lody.ai)` 后暴露出 3 个体验与协议问题：
1. **缺少模型选择器**：此前将 `Lody Agent Config` 复用塞进了 `defaultModels[.lody]` / `plan.model`，导致选 Lody 时只能选 Agent（如 `Lody · Antigravity`），无法进一步选择具体模型（如 `Gemini 4 Neon` / `Claude Opus 5.5` / `Opus 5.5` / `6.2 Sol`）。
2. **Agent 配置重复且不同步**：`默认执行与唤起偏好` 与 `Lody.ai 工作区编排设置` 两处同时出现 `Agent 配置` 下拉框，绑定不同字段导致状态打架。
3. **非交互 `npx` 缺 `-y` 风险**：实测本机执行 `npx lody ...` 在无缓存时会因缺少 `-y` 直接取消退出；同时官方 `lody session create` 原生支持 `--model <modelId>`、`--mode <modeId>` 与 `--config-option <key>=<value>`，此前尚未透传。

---

## 2. 本轮核心改动

1. **Lody 实时目录探测与 0ms 本地缓存**（`CollaborationModels.swift`、`EnvironmentDetector.swift`、`SettingsStore.swift`）
   - 新增 `LodyWorkspaceOption`、`LodyAgentConfigOption`、`LodyCatalogSnapshot`，支持通过官方 `lody workspace list --json` 与 `lody agent-config list --json` 异步拉取当前工作区的真实 Workspace、Agent Config（含 `Antigravity` / `Claude Code` / `Codex` / `Kimi Code` / `Grok` 等）、真实模型列表、思考强度配置键（`thought_level` / `effort` / `reasoning_effort`）及只读/计划模式（`plan` / `read-only`）。
   - 解析器兼容 `lody` stdout 前导传输日志行（如 `[ws] Remote Streams transport attached`），并将最新目录缓存至 `lody-catalog-cache.json`，二次启动 0ms 即显，后台异步静默刷新。
2. **解耦 `lodyAgentConfig` 与 `model`，透传官方 Lody CLI 全参数**（`ExecutionPlan`、`LodyConfig`、`AgentCommandBuilder.swift`、`AgentSessionRunner.swift`）
   - `ExecutionPlan` 新增 `lodyAgentConfig: String?`，`plan.model` 回归纯模型 ID 语义；`LodyConfig` 新增 `defaultModelByAgentConfig` 记忆每个 Lody Agent 各自偏好的默认模型，并向后兼容平滑迁移 `ITER-008` 旧 `settings.json`。
   - `buildLodySessionCommand` 改用 `npx -y lody`，并按实测能力自动拼接 `--agent-config`、`--model`、`--mode`（`plan`/`read-only`）与 `--config-option <effortKey>=<effort>`。
   - `AgentSessionRunner` 固定将 `.lody` 视为工作区后台会话派发，保证提示词始终采用可读 Markdown 且稳定解析返回的 `sessionId`。
3. **设置页与菜单栏确认卡片联动重构**（`SettingsView.swift`、`TaskDetailView.swift`）
   - 设置页消除重复 `Agent Config` 控件；选 `Lody` 时依次呈现 **默认 Lody Agent → 联动默认模型 → 默认思考强度 → 唤起方式（Lody 持久化会话）**，下方 `Lody.ai 工作区编排设置` 提供 Workspace 下拉选择与「刷新 Lody 目录」状态栏。
   - 菜单栏确认卡片选 `Lody` 时同时展示 **Lody Agent** 与 **模型** 两级联动菜单，底部主按钮实时反映选定模型（如 `Lody · Gemini 4 Neon 分析`）。

---

## 3. 验证结果

- `mobilebuildmcp swift-package test`：**34 passed, 0 failed, 0 skipped**（新增 Lody 目录解析、`--model/--mode/--config-option`/`npx -y` 命令构建及旧版 `settings.json` 迁移测试）。
- 离屏视觉快照验证 `detail-lody-dark.png` 与 `settings-lody-engines-light.png`：布局整洁、无裁切、无重复控件。
- `make app` 成功产出已签名 `build/CollabDock.app`。
