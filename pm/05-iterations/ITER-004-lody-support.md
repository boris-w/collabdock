# ITER-004 · 追加 Lody.ai 一等支持（四引擎探测、CLI 派发与 Deep Link）

- **日期**：2026-11-26
- **里程碑**：M1 增强（`TASK-020`）
- **关联需求**：`REQ-014`
- **关联决策**：[ADR-007](../03-architecture/decisions/ADR-007-lody-integration.md)

---

## 1. 落地内容

1. **核心领域与配置扩展（`CollabDockCore`）**：
   - `AgentEngine` 新增 `.lody`（`Lody (lody.ai)`），规则引擎支持解析评论建议 `--engine lody` / `--cli lody.ai`。
   - `AppSettings` 新增 `LodyConfig`（`workspace`、`defaultAgentConfig`、`preferNPXFallback`、`useLodyWorktree`）。
   - `AgentCommandBuilder` 支持构造官方 `lody session create --json`（及 `npx lody` 自动回退）命令，透传 `--workspace`、`--agent-config`、`--repo` 与防注入隔离 Prompt。
   - `AgentDriverCatalog` 新增 `lodySessionDeepLink(sessionID:workspace:)` 生成 `lody://session/<id>?workspace=<ws>` 直达链接。
   - `EnvironmentDetector` 新增 `probeLody`（依次检测全局 `lody` CLI、`/Applications/Lody.app` 与 `npx` 回退）。
2. **原生 SwiftUI 四引擎适配（`CollabDockApp`）**：
   - 一级收件箱底部引擎快切条升级为 4 引擎紧凑胶囊（`Claude` / `Codex` / `Agy` / `Lody`）。
   - 二级确认画布升级为四宫格选择瓷砖；选中 `Lody` 时自动切换默认唤起方式为「原生后台会话」、参数项自适应为「Agent 配置」、主 CTA 动态显示「▶ 派发到 Lody 审查/分析」。
   - 设置页「AI 引擎」新增专属 `Lody.ai 工作区编排设置` 区块与实时探测行。

---

## 2. 实测验证结果

- **单元测试**：**18/18 全部通过**（覆盖 `lody` 直调、`npx lody` 回退、`--workspace`/`--agent-config`/`--repo` 参数构造、`lody://session/...` Deep Link）。
- **离屏视觉验真**：4 引擎收件箱浅色与 Lody 详情深色截图逐像素检查无折行、无截断。
- **Release 打包**：`make app` 成功组装最新 `build/CollabDock.app`。
