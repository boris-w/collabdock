# 04 · 需求-架构-任务-代码-测试 双向追溯矩阵（Traceability Matrix）

> **维护规则**：每完成一个 `TASK`，同步更新本表的代码路径、测试覆盖和验证状态，确保任意需求都可追溯到具体代码行与测试用例。

| 需求 ID | 需求简称 | 优先级 | 里程碑 | 关联 ADR | 关联任务 | 代码实现路径 | 测试 / 验证路径 | 当前状态 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `REQ-001` | GitHub 认证与本地环境体检 | P0 | M1 | ADR-001, ADR-002 | TASK-004, TASK-005 | `Sources/CollabDockCore/Agents/EnvironmentDetector.swift` | `Tests/CollabDockCoreTests/EnvironmentDetectorTests.swift` | ✅ M1 已完成并验证 |
| `REQ-002` | GitHub 条件轮询与降级监听 | P0 | M1 | ADR-002, ADR-005 | TASK-005, TASK-006 | `Sources/CollabDockCore/Connectors/GitHub/GitHubConnector.swift`, `Storage/SQLiteTaskStore.swift` | `Tests/CollabDockCoreTests/GitHubConnectorTests.swift`, `PersistenceTests.swift` | ✅ M1 已完成并验证 |
| `REQ-003` | 跨平台可手动配置触发规则 | P0 | M0/M1 | ADR-002, ADR-005 | TASK-002, TASK-007 | `Sources/CollabDockCore/Rules/TriggerRuleEngine.swift`, `Config/SettingsStore.swift` | `Tests/CollabDockCoreTests/TriggerRuleEngineTests.swift`, `PersistenceTests.swift` | ✅ M1 规则与持久化已完成 |
| `REQ-004` | macOS 原生菜单栏与通知 | P0 | M0/M2 | ADR-001, ADR-005 | TASK-002, TASK-008, TASK-010 | `Sources/CollabDockApp/CollabDockApp.swift`, `Services/SystemIntegrationService.swift` | Light/Dark 截图验真 + `make app` | ✅ 菜单栏、原生通知与自启已就绪 |
| `REQ-005` | 人工确认门控与动态选模型 | P0 | M0/M2 | ADR-001, ADR-005, ADR-006 | TASK-002, TASK-008 | `Sources/CollabDockApp/Views/TaskDetailView.swift` | Light/Dark 离屏视觉验真 | ✅ 动态模型与双驱动确认页已就绪 |
| `REQ-006` | 隔离 Git Worktree / 上下文准备 | P0 | M3 | ADR-003, ADR-005 | TASK-011 | `Sources/CollabDockCore/Workspace/WorktreeManager.swift` | `Tests/CollabDockCoreTests/WorktreeAndRepoScannerTests.swift` | ✅ M3 已实现并验证 |
| `REQ-007` | 四引擎统一流式调度 | P0 | M0/M3 | ADR-003, ADR-006, ADR-007 | TASK-002, TASK-012 | `Sources/CollabDockCore/Agents/AgentSessionRunner.swift`, `AgentStreamParser.swift` | `Tests/CollabDockCoreTests/AgentStreamParserTests.swift`, `AgentCommandBuilderTests.swift` | ✅ M3 真实进程与流解析已实现 |
| `REQ-008` | 安全防注入与只读沙箱隔离 | P0 | M0/M3 | ADR-003, ADR-005 | TASK-002, TASK-012 | `Sources/CollabDockCore/Agents/AgentCommandBuilder.swift`, `AgentSessionRunner.swift` | 沙箱参数单测 + 环境变量 Token 剥离 | ✅ 三层防线全部落地 |
| `REQ-009` | 代码平台 Pending 草稿与行号校验 | P0 | M0/M3 | ADR-004, ADR-005 | TASK-002, TASK-013 | `Sources/CollabDockCore/Connectors/GitHub/GitHubReviewFormatter.swift`, `GitHubConnector.swift` | `Tests/CollabDockCoreTests/GitHubDeliveryTests.swift` | ✅ M3 已实现并验证 |
| `REQ-010` | 一键会话接管与多模型会诊 | P1/P2 | M3/M4 | ADR-003, ADR-006, ADR-007 | TASK-015, TASK-017 | `Sources/CollabDockCore/Agents/CouncilSynthesizer.swift`, `Services/SystemIntegrationService.swift` | `Tests/CollabDockCoreTests/CouncilSynthesizerTests.swift` | ✅ 一键接管与双模型会诊均已落地 |
| `REQ-011` | 团队分发、模板与自动更新 | P1 | M0/M4 | ADR-004 | TASK-002, TASK-007, TASK-016 | `scripts/generate-icon.swift`, `package-app.sh`, `package-dmg.sh`, `packaging/homebrew/Casks/collabdock.rb` | `make dmg` 实测产出 DMG + 团队配置合并单测 | ✅ AppIcon / DMG / Cask / 模板导入导出已就绪 |
| `REQ-012` | 三家 CLI 原生插件联动包 | P2 | M4 | ADR-001 | TASK-018 | 待创建 | 待创建 | 📋 M4 规划中 |
| `REQ-013` | 多平台可插拔连接器架构 | P0/P1 | M0/M4 | ADR-005 | TASK-002, TASK-019 | `Sources/CollabDockCore/Connectors/CollaborationConnector.swift`, `Models/CollaborationModels.swift` | `Tests/CollabDockCoreTests/DiffLineValidatorTests.swift` | 🟡 四柱抽象与能力协商已落地，M4 扩展第二平台 |
| `REQ-014` | Lody.ai 本地工作区与会话集成 | P1 | M1/M3 | ADR-007 | TASK-020, TASK-012, TASK-014 | `Sources/CollabDockCore/Agents/AgentCommandBuilder.swift`, `EnvironmentDetector.swift`, `AgentSessionRunner.swift` | `Tests/CollabDockCoreTests/AgentCommandBuilderTests.swift` + 真实 PR `boris-w/Lody#1` 端到端实跑通过 | ✅ 探测、真模型联动、本地项目路由与真实派发全链路已验真 |
