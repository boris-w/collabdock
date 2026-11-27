# 参与贡献

> **English summary**: Contributions are welcome. Build with Xcode 16+ (Swift 6) on macOS 14+, run `make test` before opening a PR, and add tests for any logic in `CollabDockCore`. Use [Conventional Commits](https://www.conventionalcommits.org/) (optionally tagged with `[REQ-xxx]` / `[ADR-xxx]` from `pm/`). For UI changes, attach light/dark snapshots generated with `--snapshot-dir`. Design docs live in `pm/` (Chinese). Issues and PRs in English or Chinese are both fine. For security issues, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

欢迎提 issue 和 PR，中文或英文都可以。较大的改动（新连接器、新引擎、改动安全相关逻辑）建议先开 issue 讨论方案。

安全问题请不要公开提 issue，按 [SECURITY.md](SECURITY.md) 私下报告。

## 开发环境

- macOS 14 及以上
- Xcode 16 或更高版本（Swift 6 工具链）；本项目是纯 SwiftPM 工程，没有 `.xcodeproj`
- 运行应用需要已登录的 `gh`，以及 `claude` / `codex` / `agy` / `lody` 中至少一个。只跑测试不需要这些

```bash
git clone https://github.com/boris-w/collabdock.git
cd collabdock
make build      # swift build
make run        # 打包 build/CollabDock.app 并启动
```

用 Xcode 开发时，直接 `open Package.swift` 即可。

## 运行测试

```bash
make test       # 全部测试
make test-unit  # 只跑单元测试
make test-e2e   # 端到端管线测试（假 GitHub HTTP + 假 agent CLI + 真实临时 git 仓库，不联网、不调用 AI）
```

提交 PR 前请确保 `make test` 通过。CI（`.github/workflows/ci.yml`）会在 macOS 上执行 `make build` 和 `make test`。

## 代码组织

- `Sources/CollabDockCore`：纯 Swift 业务逻辑，不依赖 SwiftUI。规则引擎、CLI 命令构造、流式输出解析、diff 行号校验、worktree 管理、存储等都放在这里，并且要有单元测试。
- `Sources/CollabDockApp`：SwiftUI 菜单栏应用。尽量只做界面和编排，可测试的逻辑下沉到 Core。
- `Sources/CollabDockApp/Debug`：仅 DEBUG 构建可用的调试工具（离屏截图 `--snapshot-dir`、真实 PR 端到端 `--e2e-pr`）。
- 界面文案目前只有简体中文。

涉及以下内容的改动请格外小心，并在 PR 描述里说明：

- CLI 的沙箱 / 权限参数（`AgentCommandBuilder`）
- 传给 AI 子进程的环境变量（`AgentSessionRunner` 会剥离 GitHub token）
- 提示词中对不可信输入的包裹（`<untrusted_external_data>` 等）
- 任何写 GitHub 的代码路径

## 提交信息

使用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/v1.0.0/)：

```text
<type>(<scope>): <简短描述> [REQ-xxx][ADR-xxx]
```

- `type`：`feat`、`fix`、`docs`、`refactor`、`test`、`chore`、`perf`、`ci` 等
- `scope`：可选，如 `github`、`lody`、`ui`、`rules`、`agents`
- 末尾的编号标签可选，用来关联 `pm/` 里的需求（`REQ-xxx`）、架构决策（`ADR-xxx`）或迭代记录（`ITER-xxx`）

示例：

```text
fix(github): fold out-of-range inline comments into the summary [REQ-009]
feat(agents): support codex resume for incremental re-review [REQ-010][ADR-006]
```

## PR 检查清单

- [ ] `make test` 本地通过
- [ ] `CollabDockCore` 中新增或修改的逻辑有对应测试
- [ ] 界面改动附上截图（可用 `swift run CollabDock --snapshot-dir /tmp/snapshots` 生成 Light/Dark 离屏截图）
- [ ] 用户可见的变化已记录到 `pm/06-releases/CHANGELOG.md` 的 `[Unreleased]`
- [ ] 测试数据、截图和文档中没有真实 token、私有仓库名或本机绝对路径

## 设计文档

设计文档集中在 [`pm/`](pm/README.md)（中文）：

- `pm/02-product/PRD.md`：需求（`REQ-xxx`）
- `pm/03-architecture/ARCHITECTURE.md` 与 `pm/03-architecture/decisions/`：架构与决策记录（`ADR-xxx`）
- `pm/05-iterations/`：每轮迭代的记录
- `pm/06-releases/CHANGELOG.md`：变更日志

做出新的架构决策（或推翻旧决策）时，请在 `decisions/` 下新增一份 ADR，而不是改写旧的。

## 行为准则

参与本项目即表示你同意遵守 [行为准则](CODE_OF_CONDUCT.md)。
