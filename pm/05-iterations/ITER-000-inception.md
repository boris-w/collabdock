# ITER-000 · 立项调研、全流程 PM 体系建立与原生 SwiftUI 骨架初始化

- **日期**：2026-11-26
- **里程碑**：M0
- **涉及任务**：`TASK-001`, `TASK-002`, `TASK-003`
- **关联决策**：`ADR-001`, `ADR-002`, `ADR-003`, `ADR-004`

---

## 1. 本次迭代目标

1. 完成从创意想法到清晰产品规格（PRD / UX Spec）与架构决策（ADR）的完整收敛。
2. 在产品目录下建立独立项目仓库 `reviewdock`，并打造一套覆盖全生命周期的可追溯项目管理目录 `pm/`。
3. 落地可直接编译、测试并打包为 macOS 原生菜单栏 `.app` 的双 Target SwiftUI 骨架工程，并提前把最容易出错的三块核心纯逻辑（触发规则引擎、三端 CLI 只读沙箱命令构造器、Diff 行号校验器）写好并接入单元测试。

---

## 2. 核心拍板回顾

1. **客户端形态**：原生 SwiftUI macOS 菜单栏常驻 App（`LSUIElement = true`，兼容 macOS 14.0+），不走纯 CLI 插件死胡同。
2. **触发规则策略**：同时支持 PR 评论 `@mention` 与 GitHub `review_requested`，且所有触发源、关键词、仓库范围、Bot/Draft 过滤全部支持手动配置。
3. **团队分发基因**：从首版即分离 `ReviewDockCore` / `ReviewDockApp`、预留团队模板配置结构，并提供标准 `.app` 打包脚本与完整的签名/公证/Homebrew/Sparkle 团队分发指南。

---

## 3. 交付物清单

- **项目管理体系 (`pm/`)**：完成 `01-discovery` 至 `06-releases` 六阶段文档，建立 `REQ / ADR / TASK / ITER` 统一编号与 `TRACEABILITY.md` 追溯矩阵。
- **SwiftUI 工程骨架**：
  - `Package.swift`（Swift 6 / macOS 14+ 双 Target：`ReviewDockCore`、`ReviewDockApp` + `ReviewDockCoreTests`）
  - `ReviewDockCore`：领域模型、`TriggerRuleEngine`、`AgentCommandBuilder`（覆盖 Claude / Codex / Antigravity 实测参数与只读沙箱）、`DiffLineValidator`（Hunk 解析与越界行号自动降级）。
  - `ReviewDockApp`：原生 `MenuBarExtra(.window)` + `Settings` 5 Tab 设置界面原型 + 人工确认选模型卡片（内置示例数据方便即刻预览体验）。
  - `scripts/package-app.sh` + `Makefile` + `Resources/Info.plist`：一键产出可双击运行的 `build/ReviewDock.app`。

---

## 4. 验证结果与后续计划

- **实测验证结果（2026-11-26）**：
  - `mobilebuildmcp swift-package test`：**10 tests passed, 0 failed, 0 skipped**（覆盖 `TriggerRuleEngine`、`AgentCommandBuilder` 三端只读沙箱与 Prompt 隔离、`DiffLineValidator`）。
  - `mobilebuildmcp swift-package build --target-name ReviewDockApp --configuration release`：Swift 6 严格并发下零报错编译通过。
  - `make app`：成功组装并 Ad-hoc 签名原生 `build/ReviewDock.app`（Release 二进制体积约 **1.1 MB**）。
- **下一迭代（`ITER-001` / M1）重点**：
  - 优先攻克 `TASK-004`（GUI `PATH` 补全与本机 `gh`/`claude`/`codex`/`agy` 探测 + `agy models` 实时拉取）与 `TASK-005`（真实 GitHub Notifications 条件轮询 + 评论正文二次拉取），让菜单栏里第一次跑起真实 GitHub PR 通知！
