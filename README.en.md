# CollabDock

[![CI](https://github.com/boris-w/collabdock/actions/workflows/ci.yml/badge.svg)](https://github.com/boris-w/collabdock/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](https://www.swift.org)

[简体中文](README.md) | English

A macOS menu bar app that collects the GitHub PRs waiting for your review into one inbox. After you confirm, it runs a local AI CLI (Claude Code / Codex / Antigravity / Lody) in a read-only, isolated git worktree and writes the result back as a GitHub pending review that only you can see.

> **Note:** the user interface is currently available in Simplified Chinese only.

<p align="center">
  <img src="docs/images/showcase-02-pending-multiplatform-light.png" width="380" alt="Inbox">
  <img src="docs/images/showcase-07-detail-confirm-dark.png" width="380" alt="Confirmation before running">
</p>
<p align="center">
  <img src="docs/images/showcase-08-detail-rereview-dark.png" width="380" alt="Incremental re-review">
  <img src="docs/images/settings-stats-light.png" width="380" alt="Usage statistics">
</p>
<p align="center">
  <img src="docs/images/menubar-icons-peekcat.png" width="560" alt="Menu bar icon states">
</p>

## Features

- **GitHub inbox**: polls `/notifications` with `If-Modified-Since` (304 responses don't count against the rate limit). Falls back to the Search API if the token lacks the `notifications` scope. You can also click `+` and paste a PR URL or `owner/repo#123`.
- **Trigger rules**: separate toggles for `@mentions` in PR comments (optionally only when a keyword such as `review` or `cr` is present), review requests, and team requests; repository allow/deny lists with `owner/*` wildcards; ignore draft PRs and bots.
- **Human confirmation before every run**: you pick the engine, model, reasoning effort, mode, project directory and delivery mode, then click confirm. Nothing starts before that. The full prompt can be previewed.
- **Four local engines**: `claude`, `codex`, `agy`, `lody` (falls back to `npx lody`). Model lists are fetched from the CLIs where possible (e.g. `agy models`, `lody agent-config list`).
- **Isolated worktrees**: maps `owner/repo` to a local clone (or makes a shallow clone in the cache directory) and checks out the PR head with `git worktree add --detach`. Your current branch and uncommitted changes are left alone.
- **Pending review drafts**: inline comments are validated against diff hunks; comments on lines outside the diff are folded into the summary so GitHub doesn't reject the review with 422. Code suggestions become ```` ```suggestion ```` blocks. Alternatively, write a local Markdown report only, or post a comment directly.
- **Incremental re-review**: when a PR gets new commits and you're asked to review again, the item is marked as round N. You can continue the previous session with only the new diff, start a new session with the new diff, or re-review everything. Rebases and force-pushes fall back to a full review.
- **Two-model council**: run two engines/models on the same PR in parallel; findings both agree on are marked as consensus.
- **Auto-archive**: once you approve on GitHub, or the PR is merged or closed, the item moves to "Done". PRs where you requested changes stay in the inbox.
- **Usage stats**: per-run token counts (input/output/cache/reasoning), duration and estimated cost, grouped by day, model and repository; CSV export; USD or CNY.
- **Session takeover**: reopen the session in a terminal (`claude --resume`, `codex resume`, `agy --resume`) or jump to Lody Desktop via a `lody://` link.
- **Also**: native notifications, launch at login, pause, team config import/export (JSON).

## How it works

```text
GitHub notifications / review requests
  → trigger rules + SQLite de-duplication
  → menu bar inbox
  → you review the parameters and confirm
  → isolated git worktree + local AI CLI in read-only mode (output constrained by a JSON Schema)
  → line validation → GitHub pending review / local Markdown report
  → you edit and submit (or discard) the draft on GitHub
```

With Lody, the task is dispatched as a background Lody session. You read and continue the review in Lody; CollabDock tracks the session status and usage but does not write anything back to GitHub.

## Security model

PR titles, comments and diffs are attacker-controllable input. CollabDock applies several layers:

1. **Human gate**: nothing runs automatically. An AI subprocess starts only after you click confirm.
2. **Read-only by default**:
   - Claude Code: `--permission-mode plan`, with `--allowedTools` limited to `Read,Grep,Glob` and `git diff/log/show`
   - Codex: `codex exec --sandbox read-only`
   - Antigravity: `agy --mode plan --sandbox`
   - Lody: the selected agent's read-only / plan mode, if it has one

   The mode can be changed to a writable one in settings or on the confirmation card (e.g. Codex `workspace-write`, Claude `acceptEdits`). If you do that, the read-only guarantee no longer holds.
3. **Untrusted input wrapping**: external content is wrapped in `<untrusted_external_data>` / `<untrusted_pr_diff>` tags, and the prompt tells the model not to follow instructions inside them. This reduces prompt-injection risk; it does not eliminate it.
4. **The AI subprocess never gets the GitHub token**: the token comes from `gh auth token` and is only used inside the app process to call the GitHub API. `GITHUB_TOKEN`, `GH_TOKEN` and `GH_ENTERPRISE_TOKEN` are removed from the subprocess environment. All writes to GitHub are made by the app itself after validating the structured output.
5. **Drafts by default**: the default delivery is a pending review (no `event`), visible only to you until you submit it.

Limits: the AI CLI still runs as your macOS user. If you switch it to a writable mode or one that allows arbitrary shell commands, it may be able to read other credentials on your machine (for example, the login stored by `gh` itself). CollabDock has no server and no telemetry; it only talks to the GitHub API. Network access by the AI CLIs is up to each CLI.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Requirements

- macOS 14 (Sonoma) or later
- To build from source: Xcode 16 or later (Swift 6 toolchain)
- [GitHub CLI](https://cli.github.com), logged in: `gh auth login`
  - Recommended: add the `notifications` scope with `gh auth refresh -s notifications` (without it, CollabDock falls back to the Search API with a 180 s interval)
- At least one of these CLIs installed and logged in: `claude` (Claude Code), `codex` (OpenAI Codex CLI), `agy` (Google Antigravity CLI), `lody` (or a working `npx`)
- `git`

## Install

There are no prebuilt releases yet. Build from source:

```bash
git clone https://github.com/boris-w/collabdock.git
cd collabdock
make app        # builds build/CollabDock.app (ad-hoc signed)
make run        # build and launch
```

Drag `build/CollabDock.app` to `/Applications`. `make dmg` additionally produces `build/CollabDock-<version>.dmg` and prints its SHA256.

**Gatekeeper**: the app is not notarized. An app you built yourself usually opens directly. If you got a DMG or zip from somewhere else, macOS will block the first launch. Either:

- right-click the app in Finder → Open (on macOS 15 and later, go to System Settings → Privacy & Security and click "Open Anyway"), or
- run `xattr -dr com.apple.quarantine /Applications/CollabDock.app`

`packaging/homebrew/Casks/collabdock.rb` is a Homebrew cask template only; it is not published to any tap yet.

## Quick start

1. After launch, the CollabDock icon appears in the menu bar. Open Settings:
   - **协作来源 (Sources)**: check that `gh` is logged in with the right account
   - **工作区 (Workspace)**: set the directories to search for local clones (default `~/work`, `~/projects`), or bind `owner/repo` to a directory manually
   - **AI 引擎 (Engines)**: choose the default engine, model, effort and mode
   - **触发规则 (Rules)**: adjust keywords and repository scope
2. When someone `@mentions` you in a PR comment (with a keyword) or requests your review, the PR shows up in the inbox with a notification. You can also import a PR with `+`.
3. Open the item, check the parameters on the confirmation card (an isolated worktree and a pending draft are the defaults), and confirm.
4. When it finishes, open the PR's Files tab on GitHub, edit the draft and submit it yourself. You can also open the local report, or take over the session in a terminal.

## Development

```bash
make build      # swift build (debug)
make test       # all tests
make test-unit  # unit tests only
make test-e2e   # end-to-end pipeline tests: fake GitHub HTTP + fake agent CLI + real temp git repo; no network or AI needed
make coverage   # all tests + CollabDockCore line-coverage gate (used by CI)
make run        # package the .app and relaunch
```

Debug builds include two developer entry points (not compiled into release builds):

```bash
# Render offscreen light/dark snapshots of the UI for visual regression
swift run CollabDock --snapshot-dir /tmp/collabdock-snapshots

# Run the full pipeline against a real PR (really calls the local AI CLI; writes a local report by default)
swift run CollabDock --e2e-pr owner/repo#123 --engine claude   # one of: claude | codex | agy | lody
```

`--e2e-pr` also accepts `--model <id>` and `--delivery <localDraftOnly|platformDraft|directReply>`.

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## Project layout

```text
Sources/CollabDockCore/   Pure Swift library, no SwiftUI: GitHub connector, rule engine,
                          CLI command building and stream parsing, worktrees, SQLite storage, usage stats
Sources/CollabDockApp/    SwiftUI menu bar app: views, design system, system integration, DEBUG tools
Tests/CollabDockCoreTests/ Unit tests
Tests/CollabDockE2ETests/  End-to-end pipeline tests (fake GitHub HTTP + fake agent CLI + temp git repo)
scripts/                  Build .app / .dmg, generate the icon
packaging/homebrew/       Homebrew cask template
pm/                       Design docs (Chinese): PRD, architecture, ADRs, iteration log, changelog
```

Requirements (`REQ-xxx`), architecture decisions (`ADR-001` to `ADR-007`) and per-iteration notes live in [`pm/`](pm/README.md).

## Roadmap

- A second connector (e.g. GitLab merge requests, Feishu chats/docs). The core already abstracts `CollaborationSource` / `CollaborationSink`, but only GitHub is implemented.
- Native plugins for Claude Code / Codex / Antigravity to browse and claim the same task queue from inside a CLI session.
- Signed and notarized releases, a Homebrew tap and auto-update.

## Notes

- The UI is Simplified Chinese only for now.
- This project is not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI, Google or Lody. Product names and trademarks belong to their respective owners.
- Costs and data handling of each AI CLI are governed by that provider's terms.

## License

[MIT](LICENSE)
