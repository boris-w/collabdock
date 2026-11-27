# ITER-018：品牌图标与菜单栏视觉重塑（猫坞 PeekCat · 暖杏小黑猫 × 歪头招手猫）

- **关联编号**：`REQ-004`、`REQ-011`、`TASK-016`
- **日期**：2026-11-27
- **状态**：已完成（母版原画、`AppIcon.icns`、原生 6 态菜单栏 Template 矢量与 `CollabDock.app` 全部落地并完成像素级视觉验真）

---

## 1. 迭代背景与问题诊断

对旧版图标做全尺寸拆包体检后，发现两处核心视觉短板：

1. **App Icon（旧版代码手绘三层菱形 + 4 颗微色点）**：
   - 图形隐喻与软件界通用图层标高度撞车，缺少「多平台协作汇聚 + 本地 AI 调度坞站」的品牌记忆点；
   - `CollabDock` 是 `LSUIElement = true` 的菜单栏常驻应用，最高频露出场景是 **32~40pt 通知横幅**与 Spotlight；旧版底部 4 颗引擎小点缩至 32px 时糊成噪点，底层 11% 透明度菱形几乎融入背景；
   - 旧脚本使用普通 `CGPath(roundedRect:)`，未贴合 Apple 原生连续曲率 Squircle。
2. **菜单栏常驻图标（旧版通用 SF Symbol）**：
   - 常态用 `square.stack.3d.up`（还与 Linear 平台图标撞车），暂停直接切换 `pause.circle`、运行中切换 `arrow.trianglehead.2.clockwise.rotate.90`——切换状态就“变脸”，丢失品牌视觉锚点；
   - 未体现 `UX_SPEC.md` 规划的「草稿已就绪」与「同步/认证异常」状态。

---

## 2. 两轮交互式设计探索与选型沉淀

本轮以 **Manus Cue × Grok Bot** 极简萌系为方向，保留完整交互式 HTML 评选过程于本迭代资产目录：

1. **第一轮 · 6 大角色方向初选**：[`assets/ITER-018/icon-showcase.html`](./assets/ITER-018/icon-showcase.html)
   - 并行产出 6 套完整角色方案（`#01 坞仔 Docky`、`#02 球球 CueBuddy`、`#03 盒盒 MiniDock`、`#04 猫坞 PeekCat`、`#05 团子 MochiPuff`、`#06 双子 DuoBots`），支持顶部真实 macOS 菜单栏 6 态试戴、38px 通知横幅、Dock 混排与新旧对比。
   - **选定方向**：**`#04 猫坞 PeekCat`**（极简几何小猫搭着小爪在 Dock 横栏上探头——既呼应开发者文化，又天然契合菜单栏“探头提醒”场景）。
2. **第二轮 · 猫坞 PeekCat 9 套配色与造型深化**：[`assets/ITER-018/peekcat-studio.html`](./assets/ITER-018/peekcat-studio.html)
   - 在基准款上延展 5 套氛围配色（薰衣草 / 暗夜奶白 / 暖杏奶油 / 薄荷晴空 / 蜜桃橘猫）与 4 套形态材质升级（Tahoe 液态玻璃 / 歪头招手 / 调度耳麦 / 纯 2D 扁平），搭配 4 套 18×18pt 菜单栏小猫轮廓与 3 槽 PK 对比。
   - **最终拍板组合**：**`V2 暖杏小黑猫配色`（燕麦暖米白底 + 哑光浓缩黑猫 + 暖杏内耳与桃粉腮红 + 砂岩奶白 Dock 栏） × `V6 歪头招手猫造型`（逆时针微歪头 + 右爪举起打招呼）**，菜单栏统一采用歪头招手猫单色 Template 矢量。

---

## 3. 工程落地改动

1. **App Icon 母版与原生连续曲率管线**
   - 新增 1024×1024 融合母版原画 [`Resources/AppIconMaster.png`](../../Resources/AppIconMaster.png)。
   - 重写 [`scripts/generate-icon.swift`](../../scripts/generate-icon.swift)：直接调用 SwiftUI `RoundedRectangle(cornerRadius: w * 0.2237, style: .continuous)` 构造 Apple 原厂连续曲率 Squircle，配合 9.8% HIG 光学留白、柔和暖灰外阴影、顶部微光渐层与浅色模式防融边极细暖棕描边，输出 10 档分辨率至 [`Resources/AppIcon.icns`](../../Resources/AppIcon.icns)。
   - 升级 [`scripts/package-app.sh`](../../scripts/package-app.sh)：当 `AppIconMaster.png` 或 `generate-icon.swift` 更新时自动重编 `AppIcon.icns`。
2. **原生 macOS 菜单栏「歪头招手猫」6 态 Template 图标**
   - 新增 [`Sources/CollabDockApp/Theme/PeekCatMenuBarIcon.swift`](../../Sources/CollabDockApp/Theme/PeekCatMenuBarIcon.swift)：以 CoreGraphics 绘制 18×18pt `@2x` Retina `NSImage(isTemplate = true)`，用 `.clear` 真透明镂空眼神与 Dock 分界缝，并用 `TransparencyLayer` 确保暂停态 45% 半透明无重叠深浅痕。
   - 覆盖全部 6 种业务状态且始终保留品牌轮廓锚点：`空闲`（歪头竖胶囊眼）、`待确认`（微微探高 + 数字）、`执行中`（数字 + 每 2.5s 轻眨眼 160ms，空闲零耗电）、`草稿就绪`（`^ ^` 开心笑眼 + 右上角提示点）、`已暂停`（45% 半透明 + `- -` 闭眼打盹）、`异常`（惊讶圆眼 + 右下角透明护圈 `!` 徽章）。
   - 在 [`AppCoordinator.swift`](../../Sources/CollabDockApp/AppCoordinator.swift)、[`CollabDockApp.swift`](../../Sources/CollabDockApp/CollabDockApp.swift) 接入状态与眨眼循环，并在 [`PreviewSnapshotter.swift`](../../Sources/CollabDockApp/Debug/PreviewSnapshotter.swift) 补充 `menubar-icons-peekcat.png` 7 态 1×/3× 视觉回归快照。

---

## 4. 验真与踩坑沉淀

- **Retina `NSBitmapImageRep` 双倍缩放坑**：先设 `rep.size = pointSize` 再取 `NSGraphicsContext(bitmapImageRep: rep)` 时 AppKit 会自动注入 2× CTM，导致二次放大裁切；改为先在原始像素坐标绘制完成后再设 `rep.size`，已通过 1×/3× 离屏真图确认像素无误。
- **半透明重叠痕修复**：暂停态改用 `CGContext.beginTransparencyLayer` 整体施加透明度，消除猫头与招手爪交界处的深色叠加。
- **视觉与打包验收**：逐像素检查 `AppIcon.icns`（512/128/32/16px）与菜单栏浅/深双主题 7 态快照；`make app` 成功组装签名并已重启实机验真。
