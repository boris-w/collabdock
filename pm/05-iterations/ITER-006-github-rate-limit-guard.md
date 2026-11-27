# ITER-006 · GitHub 限流防护与 304 零配额快速通道优化

- **日期**：2026-11-26
- **触发原因**：实跑截图与配额审计发现，长期全天常驻轮询下存在「缺 scope 重复撞 403」「老 PR 未变化重复拉 `/pulls`」「304 后仍每分钟跑 Search」三处配额浪费与风控隐患。
- **关联需求**：`REQ-002`
- **关联决策**：`ADR-002`

---

## 1. 落地优化项

1. **真正 304 零配额快速通道**（[GitHubConnector.swift](../../Sources/CollabDockCore/Connectors/GitHub/GitHubConnector.swift)、[AppCoordinator.swift](../../Sources/CollabDockApp/AppCoordinator.swift)）：
   - 当 `GET /notifications` 返回 `304 Not Modified`（0 配额消耗）时跳过常规 Search 请求；仅在启动首次、用户手动点「立即同步」或每隔 **15 分钟**低频对齐一次 `review-requested:@me`。
2. **`updated_at` 指纹跳过缓存**：
   - 在 Search 降级或低频对齐时缓存每个 PR 的 `updated_at`；时间戳未变化时 **0 次额外 `/pulls` 与 `/comments` 请求**，直接砍掉 95%+ 冗余 API 消耗。
3. **缺 scope 跳过撞 403 + 自动降频 180s**：
   - 已知 `gh` Token 缺少 `notifications` 权限时，不再每分钟重复撞 `/notifications` 403，直接按 **180 秒**低频走 Search 降级；用户点「立即同步」时自动重探 `gh auth status`，刷完权限无需重启 App 立即切回 304 零消耗通道。
4. **`X-RateLimit-*` 实时展示与 429/Retry-After 自动退避**：
   - 解析 `X-RateLimit-Limit` / `X-RateLimit-Remaining` / `X-RateLimit-Reset` / `Retry-After`，设置页实时展示剩余配额与上次是否 304 零消耗；遇 429 或配额耗尽自动休眠退避至重置时间。

---

## 2. 验证结果

- **单元测试**：新增 3 项限流与零配额专项测试，累计 **29/29 全部通过**。
- **打包验证**：`make app` 成功重新产出签名 `build/CollabDock.app`。
