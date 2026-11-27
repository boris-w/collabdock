import SwiftUI

@main
struct CollabDockApp: App {
    @State private var coordinator = AppCoordinator()

    init() {
        #if DEBUG
        PreviewSnapshotter.runIfRequested()
        E2EAcceptanceRunner.runIfRequested()
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(coordinator: coordinator)
        } label: {
            MenuBarStatusLabel(
                isPaused: coordinator.isPaused,
                runningCount: coordinator.runningCount,
                pendingCount: coordinator.pendingConfirmationCount,
                draftReadyCount: coordinator.draftReadyCount,
                hasSyncError: coordinator.lastSyncError != nil,
                isBlinking: coordinator.isMenuBarBlinking
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}

/// 极简单色菜单栏状态图标（猫坞 PeekCat · 歪头招手猫 Template 矢量 + 等宽数字角标）
struct MenuBarStatusLabel: View {
    let isPaused: Bool
    let runningCount: Int
    let pendingCount: Int
    var draftReadyCount: Int = 0
    var hasSyncError: Bool = false
    var isBlinking: Bool = false

    var body: some View {
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
