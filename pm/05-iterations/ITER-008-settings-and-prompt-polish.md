# ITER-008 · 设置页表单 Bug 修复、下拉选型补齐与提示词透明可控

- **日期**：2026-11-26
- **触发原因**：用户实测设置页截图反馈 3 个真实问题：
  1. macOS SwiftUI `.formStyle(.grouped)` 下空 `TextField` 无输入框、无占位符，视觉上像无法编辑的 Bug；同时旧版 `settings.json` 缺少新字段时合成 `Codable` 会回退丢配置。
  2. 设置页缺少「默认模型」下拉选择，且 Lody `默认 agent-config` 只能手输不能选。
  3. 唤起 AI 时默认注入提示词不透明、不可编辑，且派发到 Lody / 原生后台会话时误注入了 JSON Schema 强约束。
- **关联需求**：`REQ-005`, `REQ-011`, `REQ-014`

---

## 1. 落地修复与改进

1. **修复设置页隐形输入框与反引号排版 Bug**（[SettingsView.swift](../../Sources/CollabDockApp/Views/SettingsView.swift)）：
   - 全量输入框统一改为 `labeledInputRow`（明确左侧标题 + 右侧 `.textFieldStyle(.roundedBorder)` + 清晰 `prompt` 占位符），彻底消除空白不可见 Bug。
   - 清理文案中多余的 Markdown 反引号。
2. **补齐向后兼容配置解码**（[AppSettings.swift](../../Sources/CollabDockCore/Config/AppSettings.swift)）：
   - 实现自定义 `init(from decoder:)` 逐字段 `decodeIfPresent` 兜底，版本升级新增配置项绝不丢失用户已有偏好。
3. **全面改为下拉可选（告别手输）**：
   - **默认执行与唤起偏好**：新增与「默认 AI 引擎」联动的 **「默认模型 / Agent 配置」** 原生下拉 `Picker`（直接列出实测拉取的 `agy models` / Claude / Codex / Lody 选项）。
   - **Lody.ai 设置**：「默认 Agent Config」升级为原生下拉 `Picker`（`Workspace 默认 Agent` / `Claude Code` / `Codex` / `Antigravity` / `自定义 ID...`），仅当选择自定义时才展开输入框。
4. **提示词注入完全透明、可开关、可编辑，并修复 Lody/后台模式误注 JSON Schema**（[AgentCommandBuilder.swift](../../Sources/CollabDockCore/Agents/AgentCommandBuilder.swift)、[TaskDetailView.swift](../../Sources/CollabDockApp/Views/TaskDetailView.swift)）：
   - 托管模式（需回写 GitHub Pending 草稿）继续使用 JSON Schema 约束；**Lody / `claude --bg` 原生后台会话自动改为输出清晰、人类可读的 Markdown 结论**。
   - 设置页新增 **「提示词与团队」** Tab：支持总开关 `injectPresetPrompt`（开启/关闭模板注入），且每个任务模板均支持直接展开编辑名称与正文、新建模板和一键恢复默认。
   - 二级确认画布新增折叠式 **「预览提示词」**，点开即可核对本次实际发送给本地 AI 的完整 Prompt。

---

## 2. 验证结果

- **单元测试**：**33/33 全部通过**（新增后台模式 Markdown Prompt 断言、关闭模板注入断言、旧版 `settings.json` 向后兼容解码测试）。
- **视觉与打包**：确认画布三按钮条（`补充指令` / `双模型会诊` / `预览提示词`）离屏截图验真无拥挤，`make app` 已产出最新 `build/CollabDock.app`。
