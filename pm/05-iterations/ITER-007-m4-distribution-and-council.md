# ITER-007 · M4 团队分发套件与多模型会诊模式落地

- **日期**：2026-11-26
- **里程碑**：M4（阶段一完成）
- **涉及任务**：`TASK-016`（App 图标 + Universal/DMG 打包 + Homebrew Cask + 团队配置导入导出）、`TASK-017`（多模型会诊模式）
- **关联需求**：`REQ-010`, `REQ-011`
- **关联决策**：`ADR-003`, `ADR-004`

---

## 1. 落地内容

1. **多模型会诊模式（Multi-Model Council，`TASK-017`）**：
   - 新增 [CouncilSynthesizer.swift](../../Sources/CollabDockCore/Agents/CouncilSynthesizer.swift)：将双引擎并行审查的 `CodeReviewResult` 做交叉比对——同一文件 `±3` 行内的重叠发现自动合并并提权为 **`🤝 共识`** 问题，单方发现按引擎清晰标注；非代码类任务自动合并双视角回复草稿与去重引用文件。
   - [AppCoordinator.swift](../../Sources/CollabDockApp/AppCoordinator.swift) 支持 `async let` 在**同一个隔离只读 Git Worktree** 内并行执行主引擎与会诊搭档，支持一键同时中止两个子进程，最终统一交由 `GitHubConnector.deliver` 提交合并后的 Pending Review 草稿与本地 Markdown 报告。
   - [TaskDetailView.swift](../../Sources/CollabDockApp/Views/TaskDetailView.swift) 新增默认折叠的「双模型会诊」微开关（平时零视觉负担），展开后一行选择会诊搭档引擎与模型，主 CTA 动态切换为 **`双模型会诊 (Claude×Codex)`**。
2. **团队分发与安装工程化（`TASK-016`）**：
   - 新增原生 macOS 图标生成脚本 [generate-icon.swift](../../scripts/generate-icon.swift) 并生成多分辨率 [AppIcon.icns](../../Resources/AppIcon.icns)（深石墨圆角方砖 + 三层协作棱镜 + 四引擎微色点），已写入 `Info.plist` (`CFBundleIconFile`) 并自动打入 `CollabDock.app`。
   - 升级 [package-app.sh](../../scripts/package-app.sh) 支持 `UNIVERSAL=1` 构建 `arm64 + x86_64` Universal Binary。
   - 新增 [package-dmg.sh](../../scripts/package-dmg.sh) 与 `Makefile` `dmg` / `universal-dmg` 目标，一键产出带 `/Applications` 软链的压缩 `.dmg` 安装包并打印 Homebrew Cask 所需 `SHA256`。
   - 新增开箱即用的 [packaging/homebrew/Casks/collabdock.rb](../../packaging/homebrew/Casks/collabdock.rb) Formula 模板。
   - [SettingsView.swift](../../Sources/CollabDockApp/Views/SettingsView.swift) 补齐「团队配置包」一键导出复制 + 一键从剪贴板导入合并（保留个人账号、本地目录与模型偏好）。

---

## 2. 实测验证结果

- **单元测试（`mobilebuildmcp swift-package test`）**：**31/31 全部通过**（新增 `CouncilSynthesizerTests` 覆盖 `±3` 行共识合并、严重度提权、裁决仲裁与双视角回复合并）。
- **App Icon 视觉验真**：导出 512×512 PNG 逐像素确认边缘留白、三层棱镜与四引擎微点清晰均衡。
- **DMG 打包验真**：`make dmg` 成功产出 `build/CollabDock-0.1.0.dmg` 与 `SHA256`。
