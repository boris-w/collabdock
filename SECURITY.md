# Security Policy / 安全策略

[English](#english) | [简体中文](#简体中文)

## English

CollabDock feeds untrusted content (PR titles, comments, diffs, repository files) to local AI CLIs and writes results back to GitHub, so security reports are taken seriously.

### Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through GitHub's private vulnerability reporting:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability** (or open <https://github.com/boris-w/collabdock/security/advisories/new>).
3. Describe the issue, affected version or commit, reproduction steps, and the impact you observed.

This is a personal project maintained on a best-effort basis. I aim to acknowledge reports within 7 days and will coordinate a fix and disclosure through the GitHub Security Advisory.

### Supported versions

The project is pre-1.0. Only the latest commit on `main` (and the latest release, once releases exist) receives fixes.

### In scope

- **Prompt injection via PR content** that, with the default read-only modes, makes the AI CLI modify files, run commands beyond the allowed read-only set, or causes CollabDock to act without the user's explicit confirmation.
- **Token leakage to the AI subprocess**: the GitHub token reaching the CLI process through environment variables, command-line arguments, the prompt, files in the worktree, logs or local reports.
- **Sandbox flag problems**: default read-only flags (`--permission-mode plan` / `--allowedTools`, `--sandbox read-only`, `--mode plan --sandbox`, Lody read-only modes) missing, ineffective, or replaced by a writable mode the user did not choose.
- **Argument or command injection** through PR metadata (repository names, branch names, titles) into CLI arguments, `git` commands or file paths.
- **Worktree isolation failures**: writes to the user's main working copy, or path traversal out of the cache directory.
- **Unintended GitHub writes**: publishing a non-draft review or comment when the user selected a draft or local-only delivery.

### Out of scope

- Vulnerabilities in the AI CLIs themselves (`claude`, `codex`, `agy`, `lody`) or in `gh`. Please report those to their vendors. (If CollabDock invokes them insecurely, that is in scope.)
- Behavior after the user explicitly switches to a writable or full-access mode.
- The model producing inaccurate or misleading review text that the user reviews before submitting.
- Attacks that require an already compromised macOS user account.

## 简体中文

CollabDock 会把不可信内容（PR 标题、评论、diff、仓库文件）交给本地 AI CLI，并把结果写回 GitHub，因此我们重视安全问题。

### 如何报告

**请不要通过公开 issue 报告安全问题。**

请使用 GitHub 的私密漏洞报告功能：

1. 打开仓库的 **Security** 标签页；
2. 点击 **Report a vulnerability**（或直接打开 <https://github.com/boris-w/collabdock/security/advisories/new>）；
3. 写明问题描述、受影响的版本或 commit、复现步骤和实际影响。

这是个人维护的项目，会尽力在 7 天内回复，并通过 GitHub Security Advisory 协调修复和披露。

### 支持的版本

项目尚处于 1.0 之前，只对 `main` 分支最新提交（以及有发布之后的最新版本）提供修复。

### 范围

属于范围内：

- **通过 PR 内容进行的提示词注入**：在默认只读模式下，让 AI CLI 修改文件、执行允许范围之外的命令，或让 CollabDock 在用户未确认的情况下执行操作。
- **token 泄露给 AI 子进程**：GitHub token 通过环境变量、命令行参数、提示词、worktree 中的文件、日志或本地报告到达 CLI 进程。
- **沙箱参数问题**：默认只读参数（`--permission-mode plan` / `--allowedTools`、`--sandbox read-only`、`--mode plan --sandbox`、Lody 只读模式）缺失、失效，或被替换成用户没有选择的可写模式。
- **参数 / 命令注入**：通过 PR 元数据（仓库名、分支名、标题）注入到 CLI 参数、`git` 命令或文件路径中。
- **worktree 隔离失效**：写入了用户的主工作目录，或路径穿越出缓存目录。
- **非预期的 GitHub 写入**：用户选择草稿或仅本地时，却发布了正式 review 或评论。

不属于范围：

- AI CLI（`claude`、`codex`、`agy`、`lody`）或 `gh` 本身的漏洞，请报告给对应厂商（CollabDock 以不安全的方式调用它们则属于范围内）。
- 用户主动切换到可写或完全访问模式之后的行为。
- 模型生成了不准确或误导性的审查内容（用户在提交前会审阅）。
- 需要事先攻陷 macOS 用户账户的攻击。
