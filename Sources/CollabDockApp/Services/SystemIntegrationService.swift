import AppKit
import Foundation
import ServiceManagement
import UserNotifications
import CollabDockCore

/// macOS 系统集成能力协议（通知、开机自启、界面语言覆盖与打开 Lody 会话），用于 `AppCoordinator` 依赖注入与单测隔离
@MainActor
public protocol SystemIntegrating: AnyObject {
    var onNotificationSelectedItem: ((String) -> Void)? { get set }
    func configureNotificationsIfAvailable()
    func postIncomingTaskNotification(for item: CollaborationItem, enabled: Bool)
    func postCompletionNotification(for item: CollaborationItem, summary: String, enabled: Bool)
    func setLaunchAtLogin(_ enabled: Bool) -> String?
    func applyInterfaceLanguage(_ appleLanguages: [String]?)
    func relaunchApplication()
    func openSessionHandoff(handle: AgentSessionHandle, lodyWorkspace: String?)
}

public extension SystemIntegrating {
    func relaunchApplication() {}
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
        content.title = L("CollabDock · Draft Ready")
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
            return L("Launch at login requires running from the packaged CollabDock.app")
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return L("Failed to configure launch at login: %@", error.localizedDescription)
        }
    }

    // MARK: - 界面语言覆盖（App 级 AppleLanguages，重启后生效）

    public func applyInterfaceLanguage(_ appleLanguages: [String]?) {
        if let langs = appleLanguages, !langs.isEmpty {
            UserDefaults.standard.set(langs, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }

    public func relaunchApplication() {
        guard isRunningInsideAppBundle else { return }
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - 一键打开 Lody 会话（Lody Deep Link）

    public func openSessionHandoff(handle: AgentSessionHandle, lodyWorkspace: String?) {
        guard handle.engine == .lody else { return }
        let lodyBackend = LodyBackend(config: LodyConfig(workspace: lodyWorkspace ?? ""))
        if let deepLink = lodyBackend.sessionDeepLink(for: handle) {
            NSWorkspace.shared.open(deepLink)
            return
        }
        let command = lodyBackend.resumeShellCommand(for: handle)
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
}
