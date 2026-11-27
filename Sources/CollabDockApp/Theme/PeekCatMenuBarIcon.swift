import AppKit
import CoreGraphics
import SwiftUI

/// CollabDock 菜单栏专属「猫坞 PeekCat · 歪头招手猫」单色 Template 矢量渲染器
/// - 以 18×18pt（@2x Retina 36×36px）原生 `NSImage(isTemplate = true)` 输出，自动适配 macOS 浅色/深色/Liquid Glass 菜单栏材质
/// - 所有状态均保留品牌歪头招手猫轮廓作为视觉锚点，通过眼神与微角标表达状态变化
enum PeekCatMenuBarState: Hashable {
    case idle
    case pending
    case running(blinking: Bool)
    case draftReady
    case paused
    case error
}

@MainActor
enum PeekCatMenuBarRenderer {
    private static var cache: [PeekCatMenuBarState: NSImage] = [:]

    /// 返回可直接用于 `Image(nsImage:)` 的 18×18pt macOS Template 图标
    static func templateImage(for state: PeekCatMenuBarState) -> NSImage {
        if let cached = cache[state] {
            return cached
        }
        let img = renderImage(state: state, pointSize: 18, pixelScale: 2, asTemplate: true, tintColor: .black)
        cache[state] = img
        return img
    }

    /// 供视觉回归/快照验证导出非 Template 实体着色图
    static func renderImage(
        state: PeekCatMenuBarState,
        pointSize: CGFloat,
        pixelScale: CGFloat = 2,
        asTemplate: Bool = true,
        tintColor: NSColor = .black
    ) -> NSImage {
        let px = Int((pointSize * pixelScale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px,
            pixelsHigh: px,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: pointSize, height: pointSize))
        }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext {
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            // 映射 22×22 顶向下设计坐标系至目标像素画布（在设置 rep.size 前绘制，避免 AppKit 自动倍增 CTM）
            let unit = CGFloat(px) / 22.0
            ctx.translateBy(x: 0, y: CGFloat(px))
            ctx.scaleBy(x: unit, y: -unit)

            drawPeekCat(in: ctx, state: state, tintColor: tintColor)
        }
        NSGraphicsContext.restoreGraphicsState()

        rep.size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        image.isTemplate = asTemplate
        return image
    }

    private static func drawPeekCat(in ctx: CGContext, state: PeekCatMenuBarState, tintColor: NSColor) {
        let isPaused = (state == .paused)
        let isPending = (state == .pending)
        let isDraft = (state == .draftReady)
        let isError = (state == .error)
        let isBlinking: Bool = {
            if case .running(let b) = state { return b }
            return false
        }()

        // 使用离屏 TransparencyLayer 统一施加 paused 透明度，避免重叠路径出现深浅叠加痕
        ctx.saveGState()
        ctx.setAlpha(isPaused ? 0.45 : 1.0)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        let solidColor = tintColor.withAlphaComponent(1.0).cgColor
        let peekY: CGFloat = isPending ? -0.75 : (isPaused ? 0.55 : 0.0)

        // 1. 歪头小黑猫主轮廓（逆时针微倾 -8°，右耳翘起；底部延展至 17.6 以保证切缝绝对水平）
        ctx.saveGState()
        ctx.translateBy(x: 10.3, y: 11.4 + peekY)
        ctx.rotate(by: -8.0 * .pi / 180.0)
        ctx.translateBy(x: -10.3, y: -(11.4 + peekY))

        let headPath = CGMutablePath()
        let py = peekY
        headPath.move(to: CGPoint(x: 3.6, y: 17.6))
        headPath.addCurve(
            to: CGPoint(x: 4.6, y: 4.5 + py),
            control1: CGPoint(x: 3.6, y: 11.4 + py),
            control2: CGPoint(x: 4.1, y: 8.1 + py)
        )
        headPath.addCurve(
            to: CGPoint(x: 6.4, y: 3.8 + py),
            control1: CGPoint(x: 4.7, y: 3.6 + py),
            control2: CGPoint(x: 5.7, y: 3.3 + py)
        )
        headPath.addLine(to: CGPoint(x: 8.6, y: 6.0 + py))
        headPath.addCurve(
            to: CGPoint(x: 10.4, y: 5.75 + py),
            control1: CGPoint(x: 9.2, y: 5.85 + py),
            control2: CGPoint(x: 9.8, y: 5.75 + py)
        )
        headPath.addCurve(
            to: CGPoint(x: 12.2, y: 6.0 + py),
            control1: CGPoint(x: 11.0, y: 5.75 + py),
            control2: CGPoint(x: 11.6, y: 5.85 + py)
        )
        headPath.addLine(to: CGPoint(x: 14.4, y: 3.8 + py))
        headPath.addCurve(
            to: CGPoint(x: 16.2, y: 4.5 + py),
            control1: CGPoint(x: 15.1, y: 3.3 + py),
            control2: CGPoint(x: 16.1, y: 3.6 + py)
        )
        headPath.addCurve(
            to: CGPoint(x: 17.1, y: 17.6),
            control1: CGPoint(x: 16.7, y: 8.1 + py),
            control2: CGPoint(x: 17.1, y: 11.4 + py)
        )
        headPath.closeSubpath()

        ctx.addPath(headPath)
        ctx.setFillColor(solidColor)
        ctx.fillPath()
        ctx.restoreGState()

        // 2. 右侧翘起招手的小猫爪（稍向外伸展并带极细弧形分界，18pt 下清晰辨出“招手”动作）
        let pawCenterY: CGFloat = isPending ? 12.3 : (isPaused ? 14.1 : 13.0)
        let pawCenterX: CGFloat = 18.0
        ctx.saveGState()
        ctx.translateBy(x: pawCenterX, y: pawCenterY)
        ctx.rotate(by: 16.0 * .pi / 180.0)
        ctx.translateBy(x: -pawCenterX, y: -pawCenterY)

        // 先在脸颊侧切出极细呼吸弧缝，让招手小爪独立辨识
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        let pawHalo = CGPath(
            roundedRect: CGRect(x: pawCenterX - 2.25, y: pawCenterY - 2.4, width: 4.5, height: 5.2),
            cornerWidth: 2.25,
            cornerHeight: 2.25,
            transform: nil
        )
        ctx.addPath(pawHalo)
        ctx.fillPath()
        ctx.restoreGState()

        let pawPath = CGPath(
            roundedRect: CGRect(x: pawCenterX - 1.55, y: pawCenterY - 1.75, width: 3.1, height: 4.3),
            cornerWidth: 1.55,
            cornerHeight: 1.55,
            transform: nil
        )
        ctx.addPath(pawPath)
        ctx.setFillColor(solidColor)
        ctx.fillPath()
        ctx.restoreGState()

        // 3. 切出猫头与 Dock 横栏之间绝对平直的呼吸缝，并清理下沿溢出
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(CGRect(x: 0.5, y: 15.3, width: 21.0, height: 5.0))
        ctx.restoreGState()

        // 底部 Dock 横栏
        let dockBar = CGPath(
            roundedRect: CGRect(x: 1.9, y: 16.65, width: 18.2, height: 2.65),
            cornerWidth: 1.32,
            cornerHeight: 1.32,
            transform: nil
        )
        ctx.addPath(dockBar)
        ctx.setFillColor(solidColor)
        ctx.fillPath()

        // 左侧搭在 Dock 横栏边缘的小圆爪（带极细透明轮廓圈）
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: 4.0, y: 14.65, width: 4.2, height: 4.2))
        ctx.restoreGState()
        ctx.setFillColor(solidColor)
        ctx.fillEllipse(in: CGRect(x: 4.7, y: 15.35, width: 2.8, height: 2.8))

        // 4. 在歪头坐标系内用 .clear 镂空绘制 6 态表情眼睛（透出真实 macOS 菜单栏背景）
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.translateBy(x: 10.3, y: 11.1 + peekY)
        ctx.rotate(by: -8.0 * .pi / 180.0)
        ctx.translateBy(x: -10.3, y: -(11.1 + peekY))

        let eyeY = 11.0 + peekY
        let leftX: CGFloat = 7.75
        let rightX: CGFloat = 12.95

        if isDraft {
            // 草稿就绪：开心弯弯笑眼 ^ ^
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.7)
            ctx.setLineCap(.round)
            for cx in [leftX, rightX] {
                ctx.beginPath()
                ctx.move(to: CGPoint(x: cx - 1.45, y: eyeY + 0.55))
                ctx.addQuadCurve(to: CGPoint(x: cx + 1.45, y: eyeY + 0.55), control: CGPoint(x: cx, y: eyeY - 1.75))
                ctx.strokePath()
            }
        } else if isPaused || isBlinking {
            // 已暂停打盹 / 执行中眨眼瞬间：柔和横线眼 - -
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.65)
            ctx.setLineCap(.round)
            for cx in [leftX, rightX] {
                ctx.beginPath()
                ctx.move(to: CGPoint(x: cx - 1.3, y: eyeY + 0.25))
                ctx.addLine(to: CGPoint(x: cx + 1.3, y: eyeY + 0.25))
                ctx.strokePath()
            }
        } else if isError {
            // 异常：惊讶小圆眼
            for cx in [leftX, rightX] {
                ctx.fillEllipse(in: CGRect(x: cx - 1.35, y: eyeY - 1.35, width: 2.7, height: 2.7))
            }
        } else {
            // 空闲 / 待确认 / 执行中常态：标志性 Grok 竖胶囊眼
            let eyeH: CGFloat = isPending ? 4.4 : 4.1
            let eyeW: CGFloat = 2.05
            for cx in [leftX, rightX] {
                let eyeRect = CGRect(x: cx - eyeW / 2, y: eyeY - eyeH / 2, width: eyeW, height: eyeH)
                let eyePath = CGPath(roundedRect: eyeRect, cornerWidth: eyeW / 2, cornerHeight: eyeW / 2, transform: nil)
                ctx.addPath(eyePath)
                ctx.fillPath()
            }
        }
        ctx.restoreGState()

        // 5. 状态微角标（草稿就绪：右上角实心点；异常：右下角清晰感叹号徽章）
        if isDraft {
            ctx.setFillColor(solidColor)
            ctx.fillEllipse(in: CGRect(x: 17.3, y: 1.2, width: 3.9, height: 3.9))
        } else if isError {
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: 14.3, y: 13.8, width: 7.4, height: 7.4))
            ctx.restoreGState()

            ctx.setFillColor(solidColor)
            ctx.fillEllipse(in: CGRect(x: 15.1, y: 14.6, width: 5.8, height: 5.8))

            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 18.0, y: 16.0))
            ctx.addLine(to: CGPoint(x: 18.0, y: 17.75))
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: 17.35, y: 18.55, width: 1.3, height: 1.3))
            ctx.restoreGState()
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
