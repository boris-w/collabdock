# ADR-004 · 默认回写 GitHub Pending Review 草稿与团队分发体系

- **状态**：Pending Review 草稿回写部分已被 [ADR-008](ADR-008-lody-only-execution.md) 取代（2026-11-28）；团队分发部分仍有效
- **日期**：2026-11-26
- **关联需求**：[REQ-009](../../02-product/PRD.md#req-009--github-pending-review-草稿回写与行号校验p0), [REQ-011](../../02-product/PRD.md#req-011--团队分发团队模板与自动更新p1)

## 背景

1. 本地 AI 生成的 Review 意见将以开发者的**个人 GitHub 身份**出现，若未经二次过目直接发布，一旦出现误报或语气失当会直接影响团队信任。
2. 产品明确需要分发给团队其他成员使用，macOS Gatekeeper 对未签名/未公证应用的拦截会严重阻碍团队采纳。

## 决策

### 1. 默认回写策略：GitHub Pending Review Draft
- 调用 `POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews` 时默认**不传 `event` 字段**，创建仅本人可见的 Pending Review 草稿。
- 提交前由 `DiffLineValidator` 校验每条 Inline Comment 的 `(path, line, side)` 是否位于 PR Diff Hunk 内；越界项自动归入顶层 Summary，消除 API `422` 失败。
- 同时在 UI 中允许用户按需切换为「仅本地报告」或「直接发表 Comment（自动追加 AI 辅助尾标）」。

### 2. 团队分发策略（分阶段）
- **内测阶段（M1–M3）**：通过 `scripts/package-app.sh` 产出 `.app` / `.zip`（Ad-hoc 签名），提供团队内测安装指令（含移除 quarantine 引导）。
- **团队正式分发（M4）**：
  1. 使用团队 **Apple Developer ID Application** 证书开启 Hardened Runtime 签名，并通过 `xcrun notarytool` 完成 Apple Notarization 公证 + `stapler` 装订。
  2. 提供 **DMG 拖拽安装包** 与 **团队私有/公开 Homebrew Cask Tap**（`brew install --cask reviewdock`）。
  3. 集成 **Sparkle 2** 自动更新框架，基于 GitHub Releases 托管 `appcast.xml`，让团队成员在菜单栏一键无感升级。
  4. 提供 **团队配置包（`team-preset.json`）** 导入/导出，统一团队仓库规则与 Review Prompt 标准。

## 影响与权衡

- **正面**：Pending Draft 把 AI 的“审阅效率”与人的“最终把关”完美结合；正规签名 + Homebrew + Sparkle 让团队分发体验达到商业级原生工具水准。
- **前提条件**：正式对外/全员免告警分发需要 Apple Developer Program 账号（个人或公司均可）；在此之前可通过内测脚本流畅验证全部核心功能。
