import SwiftUI

/// 极简单色菜单栏状态图标（猫坞 PeekCat · 歪头招手猫 Template 矢量 + 等宽数字角标）
public struct MenuBarStatusLabel: View {
    public let isPaused: Bool
    public let runningCount: Int
    public let pendingCount: Int
    public var draftReadyCount: Int = 0
    public var hasSyncError: Bool = false
    public var isBlinking: Bool = false

    public init(
        isPaused: Bool,
        runningCount: Int,
        pendingCount: Int,
        draftReadyCount: Int = 0,
        hasSyncError: Bool = false,
        isBlinking: Bool = false
    ) {
        self.isPaused = isPaused
        self.runningCount = runningCount
        self.pendingCount = pendingCount
        self.draftReadyCount = draftReadyCount
        self.hasSyncError = hasSyncError
        self.isBlinking = isBlinking
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: PeekCatMenuBarRenderer.templateImage(for: iconState))
                .renderingMode(.template)
            if runningCount > 0 {
                Text("\(runningCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            } else if pendingCount > 0 {
                Text("\(pendingCount)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    private var iconState: PeekCatMenuBarState {
        if runningCount > 0 {
            return .running(blinking: isBlinking)
        }
        if isPaused {
            return .paused
        }
        if hasSyncError {
            return .error
        }
        if pendingCount > 0 {
            return .pending
        }
        if draftReadyCount > 0 {
            return .draftReady
        }
        return .idle
    }
}
