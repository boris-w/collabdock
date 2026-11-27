import SwiftUI
import CollabDockApp

@main
struct CollabDockMainApp: App {
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
