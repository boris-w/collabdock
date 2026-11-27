# 01 · 立项调研与可行性分析

> **阶段定位**：记录 ReviewDock 立项前的用户痛点分析、三家 AI CLI 实测调研、竞品差异化定位与产品形态取舍。  
> **关联文档**：[PRD.md](../02-product/PRD.md) | [ADR-001](../03-architecture/decisions/ADR-001-native-swiftui-menubar.md) | [ADR-003](../03-architecture/decisions/ADR-003-unified-cli-adapter-and-sandbox.md)

---

## 1. 背景与核心痛点

研发团队在 GitHub PR 协作中常需要同事或自己介入做 Code Review。现有云端 AI Review 方案（CodeRabbit、GitHub Copilot Review、Claude GitHub Action 等）存在四个明显短板：

1. **订阅额度割裂**：开发者本机已有 Claude Code、OpenAI Codex CLI、Google Antigravity CLI 订阅，但云端方案需要额外按量购买 API Key 或企业 SaaS 席位。
2. **强依赖仓库管理员权限**：云端 Bot 需要仓库 Admin 安装 GitHub App 或修改 `.github/workflows`，对跨团队仓库或受限仓库极不友好。
3. **上下文受限**：云端 Bot 通常只能看到单个 Diff，缺少完整本地仓库上下文、私有依赖、本地规则（`CLAUDE.md` / `AGENTS.md`）与个人 MCP 工具链。
4. **缺少人工把关与模型灵活性**：全自动触发既容易因 Prompt Injection 带来安全风险，也无法根据 PR 难度临时决定使用哪个工具和模型；AI 直接发表评论还有以个人名义“社死”的风险。

---

## 2. 三大 AI CLI 生态与实测能力调研

### 2.1 原生插件体系局限性

| 平台 | 插件规范 | 主要能力 | 无法单靠原生插件满足的核心诉求 |
| :--- | :--- | :--- | :--- |
| **Claude Code** | `.claude-plugin/plugin.json` + Marketplace | Skills、Hooks、Subagents、MCP、Channels | Channels 需依赖运行中的会话，离线无法常驻监听；难以在 Claude 插件内自然切换 Codex / Agy |
| **Codex CLI** | `codex plugin` + Marketplace | Skills、Workflows、MCP | 无原生后台常驻事件推入机制 |
| **Antigravity CLI (`agy`)** | `plugins/<name>/plugin.json` | Skills、Rules、Hooks、MCP、Sidecars | Sidecars 仅限 `agy` 生态，无法跨三家通用 |

**调研结论**：三家原生 Plugin 本质均为「会话内被动扩展」。要实现**后台 24h 监听 GitHub + 随时弹窗确认 + 跨三大 CLI 自由选模型**，必须以**独立本地常驻应用**作为核心调度器，将三家 CLI 作为可插拔的执行引擎，后续再按需补充原生 CLI 插件用于会话内联动。

### 2.2 本机实测 CLI 自动化接口对照（2026-11-26 实测）

通过实测本机已安装的 `/opt/homebrew/bin/claude`、`/usr/local/bin/codex`、`/opt/homebrew/bin/agy`，确认三者**全部支持无头执行、模型指定、思考强度、流式 JSON、Schema 结构化输出、只读沙箱与会话恢复**：

| 维度 | Claude Code (`claude`) | OpenAI Codex (`codex`) | Antigravity CLI (`agy`) |
| :--- | :--- | :--- | :--- |
| **无头模式** | `claude -p "<prompt>"` | `codex exec "<prompt>"`（另有 `codex review`） | `agy -p "<prompt>"` |
| **指定模型** | `--model <alias\|id>` | `-m / --model <model>` | `--model <id>`（可经 `agy models` 实时拉取） |
| **思考强度** | `--effort <low\|medium\|high\|xhigh\|max>` | `-c model_reasoning_effort=<level>` | `--effort <low\|medium\|high\|xhigh\|max>` |
| **流式进度** | `--output-format stream-json` | `--json` | `--output-format stream-json` |
| **结构化输出** | `--json-schema <schema>` | `--output-schema <file>` + `-o <file>` | `--json-schema <schema>` |
| **只读沙箱** | `--permission-mode plan` + `--allowedTools` | `--sandbox read-only`（默认） | `--mode plan --sandbox` |
| **交互接管** | `claude --resume <id>` | `codex resume <id>` | `agy --resume <id>` |

---

## 3. GitHub 触发接入调研

| 方案 | 实时性 | 配置门槛 | 休眠/断网恢复 | 团队仓库适用性 |
| :--- | :--- | :--- | :--- | :--- |
| **Notifications API 条件轮询 (`If-Modified-Since` + `X-Poll-Interval`)** | ~60 秒（遵守服务端头） | **极低**（复用 `gh auth`） | **极佳**（唤醒自动补齐） | **100% 通用（零仓库入侵）** |
| **本地 Webhook + Tunnel (ngrok/Tailscale)** | 秒级 | 高（需公网隧道+仓库 Webhook） | 差（休眠易丢包） | 受限（需仓库 Admin 权限） |
| **云端中继 Worker + 本地 SSE/WS** | 秒级 | 中（需团队部署一个轻中继） | 中（中继缓冲） | 需仓库配置 Webhook |

**关键技术发现**：
- GitHub `GET /notifications` 支持 `If-Modified-Since` 条件请求，无新通知时返回 `304 Not Modified`，**不消耗 Primary Rate Limit**。
- Notifications 线程只含元数据与 `latest_comment_url`，需二次拉取评论正文 `body` 以执行 `@mention` + 触发关键词匹配。
- `POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews` 省略 `event` 参数可创建 **Pending Review 草稿**（仅自己可见），是“个人账号 AI Review 防社死”的最佳载体。

---

## 4. 最终产品立项拍板（2026-11-26）

经过方案评估，最终拍板：
1. **产品形态**：**macOS 原生 SwiftUI 菜单栏常驻 App**（放弃纯 TUI 或重型 Electron，优先最佳原生桌面确认体验与低内存占用）。
2. **触发范围**：**同时支持 PR 评论 `@mention` 与 GitHub `review_requested` 指派，且全部支持手动开关与细粒度规则配置**。
3. **使用对象**：**不仅个人自用，同时面向团队分发**（架构与构建从第一天即考虑 macOS 14+ 兼容性、签名公证、Homebrew Cask / DMG 与配置模板导出）。
