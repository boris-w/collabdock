# AGENTS.md — AI 开发会话工作约定

> 本文件写给在本仓库工作的 AI 编码代理（Claude Code、Codex、Antigravity、Lody 会话等）。人类贡献者请看 [CONTRIBUTING.md](CONTRIBUTING.md)，两者规则一致。

## 1. 迭代一律走 GitHub PR

`main` 受仓库规则保护：**必须通过 PR 合并、CI（`Build & test (macOS)`）必须通过、只能 squash 合并、禁止强推和删除**。不要尝试直接推送 `main`。

1. 从最新 `main` 开分支：`git switch -c <type>/<short-desc>`（`type` 同提交信息，如 `feat/codex-resume`、`fix/reconcile-race`）。
2. 多个代理并行时，每个代理用**独立的 git worktree**，不要在同一个工作区里来回切分支：
   ```bash
   git worktree add ../collabdock-<branch> -b <branch> origin/main
   ```
3. 一个 PR = 一次迭代。PR 描述按模板写清目标、改动、验证方式；它取代过去 `pm/05-iterations/ITER-xxx.md` 的逐次记录。
4. 本地 `make coverage` 通过后再推送并 `gh pr create`。CI 绿灯后由仓库维护者（或被明确授权的会话）squash 合并。

## 2. 测试先行（TDD）

- 顺序：先写或修改测试（红）→ 实现（绿）→ 重构，CI 全程保持绿。
- 重构前先补「安全网」测试（在现有代码上为绿），用它守住外部行为。
- 测试与实现由不同会话分工时：
  - 测试负责人只改 `Tests/**`、`Package.swift` 的测试 target、`Makefile` 的测试目标、`.github/`；
  - 开发负责人只改 `Sources/**`；
  - **不得删除测试或削弱断言**。确需调整测试调用处（如接口改名）时，只做机械修改，并在 PR 描述里逐条列出。
- 大的重构先提交**接口骨架**（类型与签名，方法体 `fatalError("unimplemented")`），测试负责人针对接口写红灯测试后再实现。
- `make coverage` 要求 `CollabDockCore` 行覆盖率 ≥ 80%（见 `scripts/coverage.sh`），新代码不应拉低覆盖率。可测试的逻辑放进 `CollabDockCore`，App 层只做界面与状态编排。

## 3. 隐私红线（公开仓库）

测试数据、预览/演示数据、截图、文档、提交信息中**不得出现**：真实 token、私有仓库名、本机绝对路径、真实会话 / 工作区 / agent-config ID、同事的账号或姓名。

统一使用占位：`acme/*` 仓库、`/Users/dev/code/...` 路径、`alice` / `bob` / `carol` 用户、`11111111-2222-4333-8444-555555555555` 这类 UUID。注意：`git grep -E` 不支持 `\b`，扫描 UUID/SHA 时不要用 `\b`。

## 4. 看起来奇怪、但不要删的特判

这些来自真实机器上踩过的坑，都有测试守护（`Tests/CollabDockE2ETests/RealWorldGuardsE2ETests.swift` 等）：

- `npx` 回退钉住 `lody@latest`，且 Lody 子进程固定在中性临时目录启动（防止目标仓库里同名 `package.json` 劫持 `npx`）。
- 子进程环境变量剥离 `GITHUB_TOKEN` / `GH_TOKEN` / `GH_ENTERPRISE_TOKEN`，以及 `ELECTRON_RUN_AS_NODE`、`LODY_*` 会话变量。
- `agy` 模型 ID 已带强度后缀（`-high` 等）时不再传 `--effort`。
- CLI 非零退出时优先从 stdout 的 JSON `error` 提取错误（`lody --json` 把错误写在 stdout）。
- `review_requested` 通知按 PR head SHA 去重（作者推新提交后能再次触发复审）。
- PR 自动归档：`APPROVED` / `MERGED` / `CLOSED` 归档，`CHANGES_REQUESTED` 留在收件箱。
- 外部内容进入提示词前会中和 `<untrusted_*>` 边界标签，不要绕过 `AgentCommandBuilder.sanitizeUntrustedContent`。

## 5. 代码地图

- `Sources/CollabDockCore`：纯 Swift 业务逻辑（零 SwiftUI 依赖）。
  - `Services/`：`InboxSyncService`（轮询、去重、规则、退避、PR 状态对齐、导入）、`ReviewExecutionService`（准备 → 执行 / 会诊 / 后台派发 → 回写 → 持久化）。
  - `Agents/`：`ExecutionBackend` 协议与 `DirectCLIBackend`、`LodyBackend`；命令构造、流解析、会诊合并、运行票据 `ExecutionRunRegistry`。
  - `Connectors/`：`CollaborationSource` / `CollaborationSink` 协议与 GitHub 实现、`PRStateReconciler`。
  - `Storage/`：`TaskStore` 协议与 SQLite 实现；存储失败以 `PersistenceError` 上抛，不要 `try?` 吞掉。
- `Sources/CollabDockApp`：SwiftUI 菜单栏应用，`AppCoordinator` 只负责 UI 状态与调用 Core 服务。`Debug/` 下是仅 DEBUG 可用的截图与真实 PR 验收工具。
- 设计文档在 `pm/`（中文）；架构决策新增 ADR，不改写旧 ADR。

## 6. 常用命令

```bash
make build       # 编译
make test        # 全部测试
make test-unit   # 单元测试
make test-e2e    # 端到端（假 GitHub + 假 CLI + 真实临时 git 仓库，无需网络与 AI）
make coverage    # 全部测试 + Core 覆盖率门槛（CI 使用）
make snapshots   # 渲染 README 截图到 docs/images（DEBUG）
```
