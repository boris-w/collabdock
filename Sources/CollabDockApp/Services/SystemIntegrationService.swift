import AppKit
import Foundation
import ServiceManagement
import UserNotifications
import CollabDockCore

/// macOS 系统集成能力协议（通知、开机自启、接管会话与打开本地报告），用于 `AppCoordinator` 依赖注入与单测隔离
@MainActor
public protocol SystemIntegrating: AnyObject {
    var onNotificationSelectedItem: ((String) -> Void)? { get set }
    func configureNotificationsIfAvailable()
    func postIncomingTaskNotification(for item: CollaborationItem, enabled: Bool)
    func postCompletionNotification(for item: CollaborationItem, summary: String, enabled: Bool)
    func setLaunchAtLogin(_ enabled: Bool) -> String?
    func openSessionHandoff(handle: AgentSessionHandle, lodyWorkspace: String?)
    func openLocalReport(path: String)
}

/// macOS 原生系统集成服务：UNUserNotificationCenter 通知、SMAppService 开机自启、一键接管会话与打开本地报告（关联 REQ-004, REQ-010, TASK-010, TASK-015）
@MainActor
public final class SystemIntegrationService: NSObject, UNUserNotificationCenterDelegate, SystemIntegrating {
    public static let shared = SystemIntegrationService()

    public var onNotificationSelectedItem: ((String) -> Void)?

    private var isRunningInsideAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private override init() {
        super.init()
    }

    public func configureNotificationsIfAvailable() {
        guard isRunningInsideAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public func postIncomingTaskNotification(for item: CollaborationItem, enabled: Bool) {
        guard enabled, isRunningInsideAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(item.platform.displayName) · \(item.triggerKind.badgeText)"
        content.subtitle = "\(item.displayContextTag) (@\(item.triggeredBy))"
        content.body = item.triggerBody ?? item.title
        content.sound = .default
        content.userInfo = ["itemID": item.id]

        let request = UNNotificationRequest(
            identifier: "incoming-\(item.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    public func postCompletionNotification(for item: CollaborationItem, summary: String, enabled: Bool) {
        guard enabled, isRunningInsideAppBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = "CollabDock · 草稿已就绪"
        content.subtitle = "\(item.platform.displayName) · \(item.displayContextTag)"
        content.body = String(summary.prefix(140))
        content.sound = .default
        content.userInfo = ["itemID": item.id]

        let request = UNNotificationRequest(
            identifier: "done-\(item.id)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let itemID = response.notification.request.content.userInfo["itemID"] as? String
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let itemID {
                self.onNotificationSelectedItem?(itemID)
            }
        }
    }

    // MARK: - 开机自启（SMAppService）

    public func setLaunchAtLogin(_ enabled: Bool) -> String? {
        guard isRunningInsideAppBundle else {
            return "开机自启需从打包后的 CollabDock.app 运行时生效"
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "开机自启设置失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 一键接管原会话（Lody Deep Link / Terminal --resume）

    public func openSessionHandoff(handle: AgentSessionHandle, lodyWorkspace: String?) {
        let command: String
        if handle.engine == .lody {
            let lodyBackend = LodyBackend(config: LodyConfig(workspace: lodyWorkspace ?? ""))
            if let deepLink = lodyBackend.sessionDeepLink(for: handle) {
                NSWorkspace.shared.open(deepLink)
                return
            }
            command = lodyBackend.resumeShellCommand(for: handle)
        } else {
            command = DirectCLIBackend().resumeShellCommand(for: handle)
        }
        let escapedForAppleScript = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = """
        tell application "Terminal"
            activate
            do script "\(escapedForAppleScript)"
        end tell
        """

        if let appleScript = NSAppleScript(source: scriptSource) {
            var errorInfo: NSDictionary?
            appleScript.executeAndReturnError(&errorInfo)
            if errorInfo == nil {
                return
            }
        }

        // 若系统未授 Automation 权限，兜底复制命令到剪贴板并拉起终端
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminalURL, configuration: NSWorkspace.OpenConfiguration())
    }

    public func openLocalReport(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }
}
