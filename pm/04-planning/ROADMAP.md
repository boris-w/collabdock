# 04 · 里程碑路线图（Roadmap）

> **关联文档**：[PRD.md](../02-product/PRD.md) | [BACKLOG.md](./BACKLOG.md) | [TRACEABILITY.md](./TRACEABILITY.md)

---

## 里程碑总览

| 里程碑 | 阶段主题 | 覆盖需求 | 状态 | 准出标准（Exit Criteria） |
| :--- | :--- | :--- | :--- | :--- |
| **M0** | 立项、可追溯 PM 体系、视觉定型与 CollabDock 架构泛化 | REQ-003~009, REQ-013 | ✅ 已完成 | `pm/` 齐备；`CollabDockCore` + `CollabDockApp` 架构与视觉通过 Light/Dark 验真 |
| **M1** | 本机环境探测、真实 GitHubConnector 与 SQLite/配置持久化 | REQ-001, REQ-002, REQ-003 | ✅ 已完成 | 真实探测 `claude`/`codex`/`agy`/`agy models`/`gh`；304 条件轮询 + 403 自动降级；SQLite 幂等去重；17/17 单测通过 |
| **M2** | 原生通知点击直达与开机自启（补齐桌面触达） | REQ-004, REQ-005 | ✅ 已完成 | `UNUserNotificationCenter` 通知直达对应确认卡片；`SMAppService` 真实开机自启 |
| **M3** | Worktree 隔离执行、四引擎真实调度与 Pending Draft 回写 | REQ-006~009, REQ-014 | ✅ 核心代码与单测就绪（待真实 PR 验收） | `WorktreeManager`、`AgentSessionRunner`、GitHub Pending Review 回写、本地报告与一键会话接管均已落地（26/26 单测通过） |
| **M4** | 团队正式分发、真实 PR 验收与进阶能力（多模型会诊 / 第二连接器） | REQ-010~013 | 🔜 下一步 | 真实 PR 验收；DMG/签名公证/Homebrew Tap/Sparkle；多模型会诊；飞书/GitLab 第二连接器与原生 CLI 插件 |

---

## 风险与前置依赖追踪

| 风险项 | 影响里程碑 | 应对预案 |
| :--- | :--- | :--- |
| 三家 CLI 升级导致参数或流式 JSON 字段变化 | M3, M4 | Adapter 独立隔离 + 启动环境探测版本 + Schema 失败时降级 Markdown JSON 块提取 |
| macOS GUI App `PATH` 丢失导致找不到 `gh`/`claude`/`codex`/`agy` | M1, M3 | `EnvironmentDetector` 主动合并登录 Shell `PATH` + 设置页支持手动指定二进制路径 |
| GitHub Pending Review 行号越界返回 HTTP 422 | M3 | `DiffLineValidator` 强制前置校验，越界批注自动降级汇总到 Review Summary |
| 团队分发无 Apple 开发者证书时触发 Gatekeeper 拦截 | M4 | `DISTRIBUTION_GUIDE.md` 同时提供正式签名公证流与内测 Ad-hoc 安装指引 |
