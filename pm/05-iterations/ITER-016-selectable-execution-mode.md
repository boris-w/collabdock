# ITER-016：全引擎执行模式（Mode）动态探测与可选配置

- **关联编号**：`REQ-007`、`REQ-014`
- **日期**：2026-11-27
- **状态**：已完成（44 项单测全绿，确认卡片与设置页视觉验真通过，`CollabDock.app` 与 `CollabDock-0.1.0.dmg` 已重建）

---

## 1. 核心能力
1. **实时解析与回退各 Agent 真实 Mode 列表**（`CollaborationModels.swift`、`EnvironmentDetector.swift`）
   - `LodyAgentConfigOption` 新增 `modes: [AgentModeOption]`，实时提取 `lody agent-config list --json` 的 `runConfig.modes`（并兼容旧本地缓存按 `agentType` 补全回退选项）。
   - `AgentEngine` 补全直连 Claude (`plan`/`default`/`acceptEdits`/`auto`)、Antigravity (`plan`/`default`/`accept-edits`/`auto`) 与 Codex (`read-only`/`workspace-write`/`danger-full-access`) 模式列表。
2. **完整四维调度参数：Agent / 模型 / 思考强度 / 模式**（`AppSettings.swift`、`AppCoordinator.swift`、`SettingsView.swift`、`TaskDetailView.swift`、`AgentCommandBuilder.swift`）
   - 在 `设置 → AI 引擎` 与菜单栏确认卡片（首审 & 复审续聊）均开放「模式」下拉菜单，按 Lody Agent 与直连引擎独立记忆默认值（初始仍保守默认 `plan` / `read-only`）。
   - 真实透传至 Lody `--mode`（`session create` 与 `session chat`）、Claude `--permission-mode`、Antigravity `--mode` 与 Codex `--sandbox`。

## 2. 验证结果
- `mobilebuildmcp swift-package test`：**44 passed, 0 failed, 0 skipped**。
- 离屏视觉验真确认卡片 `detail-lody-dark.png` 与设置页 `settings-lody-engines-light.png` 均无裁切。
- `make dmg` 重建最新 `CollabDock.app` 与 `CollabDock-0.1.0.dmg`。
