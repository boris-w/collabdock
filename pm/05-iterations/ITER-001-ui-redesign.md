# ITER-001 · 对标爆款 macOS 菜单栏工具的视觉与交互重设计

- **日期**：2026-11-26
- **触发原因**：M0 骨架实跑反馈 UI 偏丑，典型问题为「默认系统灰色 `Picker` 瀑布堆砌」「多张卡片同时全展开导致拥挤」「固定 500pt 高度在少条目时大片死白空洞」「默认系统蓝按钮感廉价」。
- **关联需求**：`REQ-004`, `REQ-005`
- **关联决策**：`ADR-001`

---

## 1. 行业标杆调研提炼

调研了当前口碑最高的原生 macOS 开发者菜单栏工具与 macOS 26 Tahoe Liquid Glass 规范：
- **CodexBar (`steipete/CodexBar`)**：菜单栏仅用极简单色 Template 图标 + 等宽微数字；弹窗高信息密度、按引擎分块可视化、零多余装饰。
- **Magpie (`usemagpie.ai`)**：`368pt` 黄金宽度；柔和中性灰画布 + `12pt` 圆角 Grouped Inset Card + 行内轻描边胶囊切换，杜绝黑/蓝按钮墙。
- **Linear / PullBar / GitBar**：严格中性灰阶与 `0.5pt` 极细边框；仅把色彩留给 Diff `+绿/-红`、`@mention` / `Request Review` 语义徽章与状态点；行级悬停才浮现操作按钮。
- **macOS Control Center / Tahoe Liquid Glass**：渐进披露（一级列表 -> 二级平滑推入钻取详情）；根容器不覆盖系统毛玻璃/Liquid Glass 材质；从 `LSUIElement` 打开 `Settings` 前显式调用 `NSApp.activate(ignoringOtherApps: true)` 避开 Tahoe 失焦 Bug。

---

## 2. 核心重设计改动

1. **建立独立设计系统**（[DesignSystem.swift](../../Sources/ReviewDockApp/Theme/DesignSystem.swift)）：
   - 统一深浅双主题中性灰阶 Token、`RDInsetCard`、`RDHoverIconButton`、`RDPillButton`、`RDPrimaryActionButton`（全屏唯一黑白高对比主胶囊）与 `RDHairlineDivider`。
2. **一级收件箱瘦身与降噪**（[MenuBarContentView.swift](../../Sources/ReviewDockApp/Views/MenuBarContentView.swift)）：
   - 宽度收束至 `368pt`，自适应内容高度消灭大块空白。
   - 顶栏改为自定义微胶囊切换器（`待审 N` / `草稿 M`）+ 3 个 24×24 悬停图标。
   - 待确认 PR 合并进单张 Grouped Inset Card，每行含 28×28 触发语义徽章、单行标题、等宽 Diff 统计与评论预览；悬停浮现轻描边 `审查 ›` 与忽略 `×`。
   - 底部新增 CodexBar × Magpie 风格**本地引擎默认切换微条**（`● Claude` `● Codex` `● Antigravity`）。
3. **二级钻取确认画布（Control Center 推入风格）**（[PRReviewDetailView.swift](../../Sources/ReviewDockApp/Views/PRReviewDetailView.swift)）：
   - 彻底消灭原生灰色 `Picker` 瀑布，改用 **三宫格 AI 引擎选择瓷砖** + **单张 Grouped Inset 参数卡**（无框 `Menu` + `.menuIndicator(.hidden)` 自定义单箭头 + 行内 5 档思考强度胶囊）。
   - 补充审查指令默认折叠，需要时点击展开。
   - 底部唯一高对比黑白主按钮动态显示选中模型（如 **`▶ 用 Claude Opus 审查`**）。
4. **菜单栏图标精简**（[ReviewDockApp.swift](../../Sources/ReviewDockApp/ReviewDockApp.swift)）：
   - 改为极简单色分支图标 `arrow.triangle.branch` + `.monospacedDigit()` 紧凑角标，运行中切换为旋转图标。
5. **内置 DEBUG 离屏视觉回归快照工具**（[PreviewSnapshotter.swift](../../Sources/ReviewDockApp/Debug/PreviewSnapshotter.swift)）：
   - 支持 `--snapshot-dir <path>` 毫秒级渲染深浅双主题多视图 PNG，便于每次 UI 改动肉眼验真。

---

## 3. 离屏截图实测抓出的 4 个像素级细节并当场修复

1. SwiftUI `.menuStyle(.borderlessButton)` 自动追加系统下拉箭头导致与自定义箭头重叠 -> 改用 `.menuStyle(.button)` + `.menuIndicator(.hidden)` 彻底消除双箭头。
2. 详情页高度 `486pt` 导致底部 `+ 添加本次补充审查指令` 轻微裁切 -> 调整至 `516pt` 恢复完整呼吸感。
3. 列表行 Diff 放在第 1 行导致英文长 PR 标题过早截断 -> 将 `+312 -48` 移至第 2 行右侧，释放第 1 行完整标题宽度。
4. 底部状态条与引擎条重复出现「只读沙箱」文案 -> 去重并赋予引擎条「点击切换默认引擎」交互功能。

---

## 4. 可复用设计原则沉淀

- **菜单栏 Popover 严禁平铺多个表单**：列表页只做「3 秒扫描与筛选」，参数选择一律通过二级 Drill-Down 或行内轻菜单渐进披露。
- **零原生灰色 `Picker` 原则**：在自定义质感菜单栏弹窗内，使用 `Menu` + `.menuIndicator(.hidden)` 或横向微胶囊/瓷砖替代系统默认 `Picker`。
- **视觉改动必须看真图**：每次调整 SwiftUI 布局必须导出 Light/Dark 双主题真实截图逐像素检查，绝不凭想象验收。
