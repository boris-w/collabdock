# CollabDock 项目管理与全流程可追溯中心（PM Hub）

> **2026-11-28 起执行方式只保留 Lody（见 [ADR-008](03-architecture/decisions/ADR-008-lody-only-execution.md)）。** 文中关于直连 Claude Code / Codex / Antigravity CLI、托管运行、JSON Schema、双模型会诊、GitHub Pending 草稿回写和本地报告的内容已过时，仅作历史参考。

本目录是 **CollabDock（协作 Dock）**——面向 **Claude Code / OpenAI Codex CLI / Google Antigravity CLI / Lody** 的 macOS 原生 SwiftUI 多平台本地 AI 协作调度坞站——的**唯一软件工程与项目管理真实源（Single Source of Truth）**。

所有需求提出、架构拍板、任务拆解、迭代执行、视觉验收与团队发布均通过**统一编号体系**实现端到端双向追溯。

---

## 1. 当前项目仪表盘

| 字段 | 当前状态 |
| :--- | :--- |
| **产品名称** | **CollabDock（协作 Dock）**（原暂定名 `ReviewDock`，于 `ITER-002` / `ADR-005` 升级泛化） |
| **产品形态** | macOS 原生 SwiftUI 菜单栏常驻 App（支持 macOS 14.0+，原生适配 Tahoe） |
| **架构定位** | 多平台可插拔本地 AI 协作调度坞站（V1 完整打通 GitHub Connector，架构原生预留 GitLab / 飞书 / Slack / Linear / Webhook） |
| **当前阶段** | `M4 · 体验精简、用量统计、品牌视觉与团队分发`（已完成真实 PR 验收 + 增量复审续聊 + 四引擎 Token/成本统计面板 + 邮件式收件箱与自动归档 + 全引擎模式可选 + 猫坞 PeekCat 品牌图标与 6 态菜单栏重塑，测试 137 项全绿、CollabDockCore 行覆盖率 85.9%；2026-11-27 开源并改为 PR 迭代） -> 后续：`第二协作连接器（飞书/GitLab）/ 三端原生插件` |
| **最新迭代** | [ITER-018 · 品牌图标与菜单栏视觉重塑（猫坞 PeekCat）](./05-iterations/ITER-018-peekcat-brand-icon.md) |

---

## 2. 目录结构与软件生命周期映射

```text
pm/
├── README.md                              # 本文件：总览、编号规范与仪表盘
├── 01-discovery/
│   └── RESEARCH.md                        # 生态调研、三端 CLI 实测验证、形态对比
├── 02-product/
│   ├── PRD.md                             # 需求规格说明书（REQ-001 ~ REQ-014）
│   └── UX_SPEC.md                         # 原生 SwiftUI 交互规范、多平台自适应与状态机
├── 03-architecture/
│   ├── ARCHITECTURE.md                    # 四柱可插拔架构、模块契约与安全模型
│   └── decisions/                         # 架构决策记录（ADR-001 ~ ADR-008）
├── 04-planning/
│   ├── ROADMAP.md                         # M0 ~ M4 里程碑与准出标准
│   ├── BACKLOG.md                         # 可执行任务清单（TASK-001 ~ TASK-020）
│   └── TRACEABILITY.md                    # REQ -> ADR -> TASK -> 代码 -> 测试 双向追溯矩阵
├── 05-iterations/
│   ├── ITER-000-inception.md              # 立项与 M0 骨架初始化
│   ├── ITER-001-ui-redesign.md            # 对标 CodexBar/Magpie/Linear 的视觉重设计
│   ├── ITER-002-collabdock-architecture.md # 升级 CollabDock 与四柱可插拔架构重构
│   ├── ...                                # ITER-003 ~ ITER-018 全链路迭代复盘
│   └── assets/                            # 迭代期交互式设计原型与评选页面（如 ITER-018 图标选型）
└── 06-releases/
    ├── CHANGELOG.md                       # 版本变更日志（Keep a Changelog）
    └── DISTRIBUTION_GUIDE.md              # 团队分发、签名公证、Homebrew Cask 与自动更新 SOP
```

---

## 3. 统一编号与可追溯协作规范

> **2026-11-27 起迭代流程改为 GitHub PR**（仓库已开源，`main` 受保护：必须 PR + CI 通过、只允许 squash 合并）。
> - 一个 PR = 一次迭代，PR 描述（按 `.github/PULL_REQUEST_TEMPLATE.md`）取代逐次的 `ITER-XXX.md`；`05-iterations/` 保留历史记录，只在里程碑复盘时新增。
> - 待办改用 GitHub Issues，里程碑改用 GitHub Milestones；`04-planning/` 下的 BACKLOG / ROADMAP / TRACEABILITY 冻结，不再维护。
> - `REQ-XXX`、`ADR-XXX` 继续有效，可在 PR 标题或描述中引用。
> - 详见 [CONTRIBUTING.md](../CONTRIBUTING.md) 与 [AGENTS.md](../AGENTS.md)。

| 编号前缀 | 所在位置 | 维护规则 |
| :--- | :--- | :--- |
| `REQ-XXX` | `02-product/PRD.md` | 产品需求原子项（含优先级与验收标准），禁止删除旧编号。 |
| `ADR-XXX` | `03-architecture/decisions/` | 架构决策记录，演进或推翻旧决策时新建 ADR 并写明关系。 |
| `TASK-XXX` | `04-planning/BACKLOG.md` | 可执行开发/测试任务，必须绑定 `REQ-XXX` 与 `ADR-XXX`。 |
| `ITER-XXX` | `05-iterations/` | 每轮迭代真实复盘（目标、改动、暴露问题、实测结果与原则沉淀）。 |
| Git Commit | 仓库提交历史 | 提交信息附带编号，如 `feat(arch): refactor to multi-platform CollabDock [ITER-002][ADR-005]`。 |
