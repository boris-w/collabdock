# ADR-001 · 采用原生 SwiftUI + SwiftPM 双 Target 架构构建 macOS 菜单栏应用

- **状态**：已采纳（Accepted）
- **日期**：2026-11-26
- **关联需求**：[REQ-004](../../02-product/PRD.md#req-004--macos-原生菜单栏常驻与通知提醒p0), [REQ-005](../../02-product/PRD.md#req-005--人工确认门控与动态模型选择p0), [REQ-011](../../02-product/PRD.md#req-011--团队分发团队模板与自动更新p1)

## 背景

需要为个人与团队打造一个 24 小时常驻桌面、在收到 GitHub PR Review 请求时能即时弹窗确认并动态选择三大 AI CLI 与模型的本地工具。

## 备选方案

1. **纯 CLI 原生插件（Claude / Codex / Agy Plugin）**：无法在未打开终端时后台监听，且三家插件体系不互通，无法跨 CLI 选模型。
2. **Electron / Tauri 跨平台桌面应用**：虽然跨平台，但在 macOS 上打包体积、系统视觉融合度、原生通知与菜单栏交互细腻度不如原生 SwiftUI；团队当前主力开发机均为 macOS。
3. **原生 SwiftUI + SwiftPM 双 Target（`ReviewDockCore` + `ReviewDockApp`）**：零外部浏览器运行时，原生 `MenuBarExtra`、`UNUserNotificationCenter`、`SMAppService`、毛玻璃材质和极低内存占用；通过 SwiftPM 管理源码可避免 `.pbxproj` 冲突，同时用打包脚本生成标准签名的 `.app` / `.dmg`。

## 决策

采纳 **方案 3**：
- 部署目标设定为 **macOS 14.0+ (Sonoma)**，兼顾 `@Observable`、`MenuBarExtra(.window)` 现代 API 与团队成员不同 macOS 版本的广泛兼容。
- 严格拆分为无 UI 依赖的 `ReviewDockCore` 库与 `ReviewDockApp` 应用层，确保规则引擎、GitHub 协议、CLI 适配器与 Diff 校验均可 100% 脱离界面做快速单元测试。
- 使用 `scripts/package-app.sh` 将 SwiftPM 产出的二进制组装为带 `Info.plist` (`LSUIElement = true`) 的标准 `ReviewDock.app` Bundle，用于签名、公证和团队分发。

## 影响与权衡

- **正面**：启动毫秒级、常驻内存 ~25–40 MB、原生 Apple HIG 手感极佳、对 AI 辅助迭代极友好（纯 Swift 源码，无 Xcode 项目文件噪音）。
- **需注意**：GUI `.app` 不会自动继承用户 Shell `PATH`，必须在 `EnvironmentDetector` 中显式补全登录 Shell `PATH` 与 Homebrew 路径。
