#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// 生成 CollabDock 原生 macOS AppIcon.icns
// 基于 Resources/AppIconMaster.png（猫坞 PeekCat · 暖杏小黑猫配色 × 歪头招手猫造型）
// 套用 Apple HIG 连续曲率 Squircle 蒙版、9.8% 光学留白、柔和外投影与深浅色自适应描边
let args = CommandLine.arguments
let outIcnsPath = args.count > 1 ? args[1] : "Resources/AppIcon.icns"
let masterPath = args.count > 2 ? args[2] : "Resources/AppIconMaster.png"
let previewPath: String? = args.count > 3 ? args[3] : nil

let fileManager = FileManager.default
let masterURL = URL(fileURLWithPath: masterPath)

guard let masterNSImage = NSImage(contentsOf: masterURL),
      let masterCGImage = masterNSImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("[CollabDock] Error: unable to load master icon artwork at \(masterURL.path)\n", stderr)
    exit(1)
}

let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("collabdock-icon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = tempRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: tempRoot) }

/// 构造 Apple 原生连续曲率 Squircle 路径（直接调用 SwiftUI `.continuous` 22.37% 标准曲率，与系统图标像素级一致）
func makeAppleSquirclePath(in rect: CGRect) -> CGPath {
    RoundedRectangle(cornerRadius: rect.width * 0.2237, style: .continuous)
        .path(in: rect)
        .cgPath
}

func renderIcon(pixelSize: Int, source: CGImage) -> Data? {
    let s = CGFloat(pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS HIG 图标标准光学留白：内缩 9.8%（小尺寸 16/32px 略收紧至 7% 以保证主体清晰锐利）
    let insetRatio: CGFloat = pixelSize <= 32 ? 0.072 : 0.098
    let inset = s * insetRatio
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = makeAppleSquirclePath(in: rect)

    // 1. 柔和 macOS 底部外阴影（暖灰调，适配浅色/深色桌面壁纸与通知横幅）
    ctx.saveGState()
    let shadowAlpha: CGFloat = pixelSize <= 32 ? 0.18 : 0.24
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.017),
        blur: s * 0.036,
        color: NSColor(calibratedRed: 0.14, green: 0.11, blue: 0.09, alpha: shadowAlpha).cgColor
    )
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor(calibratedRed: 0.97, green: 0.94, blue: 0.90, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 2. 裁切至苹果连续曲率 Squircle 内，光学居中绘制母版原画
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // 适度光学放大 1.09× 并微调向上 1.8%，让小黑猫与 Dock 横栏在小图标里饱满居中
    let scale: CGFloat = pixelSize <= 32 ? 1.13 : 1.09
    let drawW = rect.width * scale
    let drawH = rect.height * scale
    let drawX = rect.midX - drawW / 2
    let drawY = rect.midY - drawH / 2 + rect.height * 0.018
    ctx.draw(source, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))

    // 顶部微弱玻璃高光渐层（提升 macOS 26 Tahoe 质感）
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let sheenColors = [
        NSColor(calibratedWhite: 1.0, alpha: 0.22).cgColor,
        NSColor(calibratedWhite: 1.0, alpha: 0.0).cgColor
    ] as CFArray
    if let sheen = CGGradient(colorsSpace: colorSpace, colors: sheenColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            sheen,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.28),
            options: []
        )
    }
    ctx.restoreGState()

    // 3. 克制暖棕极细边缘描边（确保暖奶油底图标在 macOS 纯白浅色模式下轮廓依然清晰干脆）
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.22, green: 0.17, blue: 0.12, alpha: 0.11).cgColor)
    ctx.setLineWidth(max(0.75, s * 0.0032))
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for item in sizes {
    guard let png = renderIcon(pixelSize: item.px, source: masterCGImage) else {
        fputs("Failed to render \(item.name)\n", stderr)
        exit(1)
    }
    try png.write(to: iconsetURL.appendingPathComponent(item.name))
}

if let previewPath, let previewPNG = renderIcon(pixelSize: 512, source: masterCGImage) {
    try previewPNG.write(to: URL(fileURLWithPath: previewPath))
}

let outURL = URL(fileURLWithPath: outIcnsPath)
try fileManager.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outURL.path]
try iconutil.run()
iconutil.waitUntilExit()
if iconutil.terminationStatus != 0 {
    fputs("iconutil failed with exit code \(iconutil.terminationStatus)\n", stderr)
    exit(iconutil.terminationStatus)
}
print("[CollabDock] Generated \(outURL.path) from \(masterURL.path)")
