import SwiftUI
import CollabDockCore

/// CollabDock 视觉设计体系（CodexBar × Magpie × Linear × macOS Tahoe Liquid Glass）
enum CDTheme {
    static let popoverWidth: CGFloat = 376
    static let detailHeight: CGFloat = 536
    static let cardCornerRadius: CGFloat = 12
    static let innerCornerRadius: CGFloat = 8

    static func cardBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.065) : Color.white.opacity(0.80)
    }

    static func cardHoverBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.038)
    }

    static func subtleSurface(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.042)
    }

    static func hairlineBorder(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
    }

    static func selectedTileFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.96)
    }

    static func selectedTileBorder(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.26) : Color.black.opacity(0.18)
    }

    static func primaryCTAFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.95) : Color(red: 0.11, green: 0.11, blue: 0.13)
    }

    static func primaryCTAText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.09, green: 0.09, blue: 0.11) : Color.white
    }

    static let diffAddition = Color(red: 0.15, green: 0.68, blue: 0.36)
    static let diffDeletion = Color(red: 0.88, green: 0.28, blue: 0.28)
    static let statusGreen = Color(red: 0.16, green: 0.72, blue: 0.38)
    static let statusAmber = Color(red: 0.90, green: 0.58, blue: 0.12)
}

extension PlatformKind {
    var symbolName: String {
        switch self {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .gitlab: return "point.3.connected.trianglepath.dotted"
        case .feishu: return "bubble.left.and.text.bubble.right"
        case .slack: return "number"
        case .linear: return "square.stack.3d.up"
        case .jira: return "checklist"
        case .customWebhook: return "antenna.radiowaves.left.and.right"
        }
    }

    var accentColor: Color {
        switch self {
        case .github: return Color(red: 0.44, green: 0.40, blue: 0.92)
        case .gitlab: return Color(red: 0.88, green: 0.44, blue: 0.22)
        case .feishu: return Color(red: 0.12, green: 0.68, blue: 0.62)
        case .slack: return Color(red: 0.78, green: 0.26, blue: 0.52)
        case .linear: return Color(red: 0.36, green: 0.44, blue: 0.92)
        case .jira: return Color(red: 0.18, green: 0.52, blue: 0.90)
        case .customWebhook: return Color(red: 0.56, green: 0.56, blue: 0.62)
        }
    }
}

extension AgentEngine {
    var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .lody: return "Lody"
        }
    }

    var compactPillName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Agy"
        case .lody: return "Lody"
        }
    }

    var symbolName: String {
        switch self {
        case .claudeCode: return "sparkle"
        case .codex: return "terminal"
        case .antigravity: return "wand.and.stars"
        case .lody: return "cube.transparent"
        }
    }

    var brandAccent: Color {
        switch self {
        case .claudeCode: return Color(red: 0.86, green: 0.48, blue: 0.30)
        case .codex: return Color(red: 0.15, green: 0.68, blue: 0.48)
        case .antigravity: return Color(red: 0.33, green: 0.52, blue: 0.96)
        case .lody: return Color(red: 0.58, green: 0.38, blue: 0.96)
        }
    }
}

extension ReasoningEffort {
    var shortLabel: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        case .xhigh: return "XH"
        case .max: return "Max"
        }
    }
}

struct CDInsetCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let padding: CGFloat
    @ViewBuilder let content: () -> Content

    init(padding: CGFloat = 0, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(
                CDTheme.cardBackground(for: scheme),
                in: RoundedRectangle(cornerRadius: CDTheme.cardCornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CDTheme.cardCornerRadius, style: .continuous)
                    .strokeBorder(CDTheme.hairlineBorder(for: scheme), lineWidth: 0.5)
            )
            .shadow(
                color: scheme == .dark ? .clear : Color.black.opacity(0.035),
                radius: 4,
                x: 0,
                y: 1
            )
    }
}

struct CDHoverIconButton: View {
    let systemImage: String
    let helpText: String
    var isActive: Bool = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : (isHovering ? .primary : .secondary))
                .frame(width: 24, height: 24)
                .background(
                    isHovering ? CDTheme.subtleSurface(for: scheme) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
    }
}

struct CDPillButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                isHovering
                    ? CDTheme.selectedTileFill(for: scheme)
                    : CDTheme.cardBackground(for: scheme),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(CDTheme.hairlineBorder(for: scheme), lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct CDPrimaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(CDTheme.primaryCTAText(for: scheme))
            .padding(.horizontal, 13)
            .padding(.vertical, 6.5)
            .background(
                CDTheme.primaryCTAFill(for: scheme).opacity(isHovering ? 0.88 : 1.0),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct CDHairlineDivider: View {
    @Environment(\.colorScheme) private var scheme
    var leadingInset: CGFloat = 12

    var body: some View {
        Rectangle()
            .fill(CDTheme.hairlineBorder(for: scheme))
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
    }
}
