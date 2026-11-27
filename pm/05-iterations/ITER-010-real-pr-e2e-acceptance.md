# ITER-010：真实 PR 端到端验收（`TASK-014`）、Lody 本地项目智能路由与 5 处实测问题修复

- **关联编号**：`TASK-014`、`REQ-006`、`REQ-007`、`REQ-009`、`REQ-014`、`ADR-007`
- **日期**：2026-11-26
- **状态**：已完成（35 项单测全绿，真实 PR `boris-w/Lody#1` 双路径实跑验收，已重建 `CollabDock.app` 与 `CollabDock-0.1.0.dmg`）

---

## 1. 真实 PR 端到端试跑中暴露并修复的 5 个真实环境问题

在真实本机环境对真实 PR（`boris-w/Lody#1` 与 `acme/backend#123`）做全链路验证时，共捕获并彻底修复了 5 个单测无法替代发现的真实问题：

1. **Lody 工作区未绑定云端 GitHub 仓导致 `--repo` 不可用**
   - 现象：`lody github list --json` 返回 `repositories: []`，但用户已将 `backend`、`Lody` 等 9 个仓库注册为 **Lody 本地项目**（`lody project list --json`）。
   - 修复：在 `EnvironmentDetector.fetchLodyCatalog` 并行探测 `lody project list --json`（兼容多行缩进 JSON，并自动读取 `.git/config` 关联 `owner/repo`）与 `lody github list --json`；引入 `LodyWorkspaceTarget` 三层智能路由：
     1. 命中 Lody 本地项目 -> 静默刷新远端 PR 分支引用后传 `--local-project <id> --worktree --branch <headRef>`；
     2. 命中 Lody 云端绑定仓库 -> 传 `--repo <owner/repo> --branch <headRef>`；
     3. 兜底 -> 由 `WorktreeManager` 创建本地隔离 Worktree 后传 `--local-project <worktreePath>`。
     - 同时自动附加可读 `--title "[CollabDock] <scope> <ref> <title>"`。
2. **在 `Lody` 同名仓目录内运行 `npx -y lody` 触发 `npm error could not determine executable to run`**
   - 现象：当审查目标仓库本身包含名为 `lody` 的 `package.json` 时，在该 `cwd` 启动 `npx -y lody` 会被本地目录劫持失败。
   - 修复：`AgentSessionRunner` 对 `.lody` 子进程固定在临时目录启动（项目路径由 `--local-project` / `--repo` 显式指定），彻底杜绝目录劫持。
3. **`agy` 模型 ID 已含强度后缀与 `--effort` 冲突**
   - 现象：`agy models` 返回的 `gemini-3.8-flash-high`、`gemini-4-neon-xhigh` 等 ID 已内嵌强度，再传 `--effort medium` 会被 `agy` 直接拒跑。
   - 修复：`AgentCommandBuilder` 新增 `modelIDEncodesEffort(_:)` 检测，已含 `-low/-medium/-high/-xhigh/-max` 后缀时自动省略 `--effort`。
4. **`agy --mode plan --sandbox` 无头模式禁止 `run_command("git diff ...")` 与嵌套 `stream-json` 未解析**
   - 现象：`agy` 非交互模式自动拒绝 Bash `git diff`，返回空响应；且 `agy` 的 `stream-json` 把最终文本放在嵌套的 `result.response`、工具进度放在 `step_update.tool_name`，此前 `AgentStreamParser` 仅查顶层字段导致原始 JSONL 事件日志泄露进报告。
   - 修复：
     - `WorktreeManager` 修复 `origin/<baseRef>` fetch refspec，并将计算好的完整 Unified Diff 作为 `<untrusted_pr_diff>` 安全内嵌至非后台托管 Prompt，AI 仅用只读 `read_file` 即可深度审查无需 Bash；
     - `AgentStreamParser` 完整支持 `agy` 嵌套 `result.response` / `result.structured_output` 与 `step_update.tool_name` 实时进度，并拦截空/原始 JSONL 误入报告。
5. **日常快捷入口补齐**：菜单栏收件箱顶栏新增 `+` 按钮，支持粘贴任意 GitHub PR 链接或 `owner/repo#编号` 直接拉取真实 PR 进收件箱确认审查。

---

## 2. 实测验收证据（真实 PR `boris-w/Lody#1`）

### 路径 A：Lody.ai 工作区真实派发（`Antigravity` + `Gemini 4 Neon`）
- 探测到 `my workspace`（5 个 Agent、36 个模型、9 个本地项目），自动将 `boris-w/Lody` 映射到 `<local-project-id>`（`~/code/Lody`）。
- 成功创建真实 Lody 会话 `<session-id>`，经 `lody session show --json` 核验：
  - `lastModel`: `Gemini 4 Neon` (`gemini-4-neon`)
  - `isWorktree`: `true`，`baseBranch`: `refs/remotes/origin/fix/all-changes-default-branch-base`
  - `title`: `[CollabDock] boris-w/Lody #1 fix(cli): compare an unrecorded base against the remote default branch`
  - 会话已完整输出带可点击文件与行号链接的人类可读 Markdown 审查结论；本地 `~/code/Lody` 原分支 `main` 零污染。
- 一键接管链接：`lody://session/<session-id>?workspace=<workspace-id>`。

### 路径 B：本地直连 `agy` 隔离 Worktree 结构化审查（`gemini-3.8-flash-low`）
- 自动通过 Lody 本地项目列表定位 `~/code/Lody`（无需改 `workspaceSearchRoots`），在 `~/Library/Caches/CollabDock/worktrees/boris-w_Lody-pr-1-2c983a7` 创建 detached worktree 并计算 `12,395` 字节 Unified Diff。
- `agy` 在 `--mode plan --sandbox` 只读沙箱内解析出完整 `CodeReviewResult`（`verdict: APPROVE`，会话 ID `<session-id>`），经 `DiffLineValidator` 校验并落盘本地 Markdown 报告 `github_boris-w_Lody_1_manual_2c983a7.md`，结束后自动清理临时 worktree，原仓库零污染。

---

## 3. 构建与测试结果

- `mobilebuildmcp swift-package test`：**35 passed, 0 failed, 0 skipped**。
- `make dmg`：重新生成已签名 `build/CollabDock.app` 与 `build/CollabDock-0.1.0.dmg`（SHA256: `<sha256>`）。
