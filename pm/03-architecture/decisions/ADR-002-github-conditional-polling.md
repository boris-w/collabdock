# ADR-002 · 默认采用 GitHub Notifications 条件轮询 + `gh` 凭据复用

- **状态**：已采纳（Accepted）
- **日期**：2026-11-26
- **关联需求**：[REQ-001](../../02-product/PRD.md#req-001--github-认证与本地运行环境体检p0), [REQ-002](../../02-product/PRD.md#req-002--github-pr-事件监听与增量拉取p0), [REQ-003](../../02-product/PRD.md#req-003--可手动配置的触发规则引擎p0)

## 背景

需要感知其他人在任意 GitHub 仓库 PR 中 `@我` 或 `Request Review` 指派我的事件，并且产品需要无缝分发给整个研发团队，零服务器运维成本。

## 备选方案

1. **本地 Webhook Server + Tunnel（ngrok / Tailscale Funnel）**：秒级延迟，但要求每个仓库管理员配置 Webhook，且笔记本合盖休眠期间会丢事件，团队成员配置成本极高。
2. **团队自建云端 Webhook 中继 + 本地 WebSocket**：秒级且可缓冲，但需要团队长期维护云服务与 GitHub App 凭据，违背首版零基础设施诉求。
3. **GitHub Notifications REST API 条件轮询 + `gh auth token` 复用**：利用 `If-Modified-Since` 与 `X-Poll-Interval` 做条件请求，并辅以 `review-requested:@me` 对齐状态。

## 决策

V1 采纳 **方案 3** 作为默认且零配置的事件接入方案：
- 凭据优先通过本机 `gh auth token` 动态读取（团队成员通常已登录 `gh`），同时允许在 macOS Keychain 录入 GitHub PAT（只需 `notifications` + `repo` 权限）。
- 轮询 `GET /notifications` 时缓存上次响应的 `Last-Modified` 发送 `If-Modified-Since`；GitHub 返回 `304 Not Modified` **不计入 Primary Rate Limit**。
- 严格遵守 `X-Poll-Interval`（默认 60 秒）防止触发 Secondary Rate Limit；命中 `PullRequest` 且 `reason` 符合配置时再二次拉取评论 `body` 与 PR 详情。
- 在架构层抽象 `GitHubEventSource` 协议，为未来有需要时无缝扩展团队内部 Webhook 中继留出扩展口。

## 影响与权衡

- **正面**：零服务器、零仓库 Admin 权限、内网/私有库直接可用、休眠唤醒自动补漏。
- **权衡**：端到端发现延迟在 30–60 秒量级，对于 PR Review 异步协作场景完全可接受，同时提供菜单栏「立即刷新」按钮满足主动拉取需求。
