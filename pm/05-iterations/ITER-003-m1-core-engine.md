# ITER-003 · M1 里程碑交付：本机环境探测、真实 GitHubConnector 与 SQLite/配置持久化

- **日期**：2026-11-26
- **里程碑**：M1（已完成准出标准）
- **涉及任务**：`TASK-004`, `TASK-005`, `TASK-006`, `TASK-007`
- **关联决策**：`ADR-002`, `ADR-005`, `ADR-006`

---

## 1. 本次迭代交付物

1. **双驱动抽象落地（`ADR-006`）**：
   - 新增 `ExecutionLaunchMode`（`.managedStructuredRun` / `.nativeBackgroundSession`）、`AgentSessionHandle` 与 `AgentDriverCatalog`（支持 `claude attach` / `claude --resume` / `codex resume` / `agy --resume` 接管命令构造）。
   - `AgentCommandBuilder` 新增 `buildBackgroundDispatchCommand`（含 `claude --bg` 后台只读沙箱派发），二级确认画布已开放「唤起方式」选择。
2. **`EnvironmentDetector` 本机实时探测（`TASK-004`）**：
   - 解决 macOS GUI `.app` 启动缺少登录 Shell `PATH` 的经典问题，自动补全 Homebrew / 用户本地路径。
   - 并发探测 `git`、`gh`、`claude`、`codex`、`agy` 真实路径与版本，**动态解析 `agy models` 全部实时模型列表**填充到菜单栏模型下拉框。
   - 自动解析 `gh auth status` 当前登录账号与 OAuth Scopes。
3. **`GitHubConnector` 真实接入与降级保护（`TASK-005`）**：
   - 实现 `GET /notifications` 条件轮询（`If-Modified-Since` 触发 `304 Not Modified` 零配额消耗 + 严格遵守 `X-Poll-Interval`）+ PR 元信息与触发评论正文二次拉取。
   - **关键实战踩坑与自愈**：本机实测发现默认 `gh auth login` 令牌通常只有 `repo` 权限而缺少 `notifications` 权限（`GET /notifications` 会返回 HTTP 403）。`GitHubConnector` 在捕获 `403` 时自动降级至 Search API（`review-requested:@me` + `mentions:@me`），并在设置页提供一键复制 `gh auth refresh -s notifications` 的友好升级指引，做到零阻塞开箱即用。
4. **`SQLiteTaskStore` 与 `SettingsStore` 持久化（`TASK-006`, `TASK-007`）**：
   - 基于 macOS 内置 `SQLite3` 实现线程安全的 `actor SQLiteTaskStore`（WAL 模式，无第三方依赖），持久化任务状态机、幂等去重键 `seen_events` 与各平台 `sync_cursors`。
   - `SettingsStore` 实现设置原子落盘及团队配置包 `TeamPreset` 导出/非破坏性合并导入。
5. **真实闭环接入 `CollabDockApp`**：
   - 应用启动后自动加载 SQLite 历史、并发体检本机 CLI 与 GitHub 登录态、执行首次真实同步并启动遵守 `X-Poll-Interval` 的后台轮询循环。
   - 设置页实时显示 GitHub 认证状态、三端 CLI 真实版本与路径、可用模型数及演示数据开关。

---

## 2. 实测验证结果

- **单元测试（`mobilebuildmcp swift-package test`）**：**17 tests passed, 0 failed, 0 skipped**（覆盖多平台规则引擎、三端只读沙箱与后台派发命令、Diff 行号校验、`agy models` / `gh auth status` 解析、GitHub 304 / 200 / 403 降级 Mock HTTP、SQLite `:memory:` 持久化与团队配置包合并）。
- **Swift 6 严格并发**：消除 `actor deinit` 捕获 `OpaquePointer` 告警，零 warning 通过 Debug & Release 编译。
- **应用打包（`make app`）**：产出真实可运行的原生 `build/CollabDock.app` 并已刷新离屏视觉快照。

---

## 3. 下一阶段（M2 / M3）计划

- **M2（原生系统触达）**：接入 `UNUserNotificationCenter` 新事件弹窗与点击直达详情页、`SMAppService.mainApp` 真实开机自启开关（`TASK-010`）。
- **M3（真枪实弹跑通本地 AI 审查与草稿回写）**：实现 `RepoScanner` + 隔离 `WorktreeManager`（`TASK-011`）、真实三端 CLI 流式执行器（`TASK-012`）与 `GitHubReviewPublisher` 提交真实 Pending Review 草稿（`TASK-013`）。
