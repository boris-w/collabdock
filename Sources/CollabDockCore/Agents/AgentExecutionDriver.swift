import Foundation

/// 原生持久会话句柄（用于一键 attach / resume 接管，关联 ADR-006）
public struct AgentSessionHandle: Codable, Hashable, Sendable {
    public let engine: AgentEngine
    public let sessionID: String
    public let workspacePath: String
    public let launchMode: ExecutionLaunchMode
    public let createdAt: Date

    public init(
        engine: AgentEngine,
        sessionID: String,
        workspacePath: String,
        launchMode: ExecutionLaunchMode,
        createdAt: Date = Date()
    ) {
        self.engine = engine
        self.sessionID = sessionID
        self.workspacePath = workspacePath
        self.launchMode = launchMode
        self.createdAt = createdAt
    }
}

public enum AgentExecutionEvent: Sendable {
    case started(sessionID: String?)
    case progress(String)
    case completed(output: ExecutionOutput, handle: AgentSessionHandle?)
    case dispatchedBackground(handle: AgentSessionHandle)
    case failed(String)
}

/// 统一本地 AI 执行驱动抽象（支持托管持久化无头模式与原生后台会话/协议双驱动，关联 ADR-006）
public protocol AgentExecutionDriver: Sendable {
    var engine: AgentEngine { get }
    var supportedLaunchModes: [ExecutionLaunchMode] { get }

    func buildResumeShellCommand(for handle: AgentSessionHandle) -> String
}

public enum AgentDriverCatalog {
    public static func supportedLaunchModes(for engine: AgentEngine) -> [ExecutionLaunchMode] {
        switch engine {
        case .claudeCode:
            return [.managedStructuredRun, .nativeBackgroundSession]
        case .codex:
            // Codex V1 托管持久化 exec 默认落盘可 resume；M4 接入 codex app-server 解锁原生后台协议
            return [.managedStructuredRun, .nativeBackgroundSession]
        case .antigravity:
            // Antigravity V1 托管持久化 -p 留存 conversationId；M4 接入 agy acp 解锁原生后台协议
            return [.managedStructuredRun, .nativeBackgroundSession]
        case .lody:
            // Lody 天然以原生持久化 Session 运行并多端同步（Desktop / Web / iOS）
            return [.nativeBackgroundSession, .managedStructuredRun]
        }
    }

    public static func defaultLaunchMode(for engine: AgentEngine, fallback: ExecutionLaunchMode) -> ExecutionLaunchMode {
        engine == .lody ? .nativeBackgroundSession : fallback
    }

    /// 构造官方 Lody Deep Link（支持从 CollabDock 一键在 Lody Desktop 打开对应会话，关联 ADR-007）
    public static func lodySessionDeepLink(sessionID: String, workspace: String? = nil) -> URL? {
        var comps = URLComponents()
        comps.scheme = "lody"
        comps.host = "session"
        comps.path = "/\(sessionID)"
        if let workspace, !workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            comps.queryItems = [URLQueryItem(name: "workspace", value: workspace)]
        }
        return comps.url
    }

    public static func resumeShellCommand(for handle: AgentSessionHandle, lodyWorkspace: String? = nil) -> String {
        let escapedDir = shellEscape(handle.workspacePath)
        let escapedID = shellEscape(handle.sessionID)
        switch handle.engine {
        case .claudeCode:
            if handle.launchMode == .nativeBackgroundSession {
                return "cd \(escapedDir) && claude attach \(escapedID)"
            }
            return "cd \(escapedDir) && claude --resume \(escapedID)"
        case .codex:
            return "cd \(escapedDir) && codex resume \(escapedID)"
        case .antigravity:
            return "cd \(escapedDir) && agy --resume \(escapedID)"
        case .lody:
            if let deepLink = lodySessionDeepLink(sessionID: handle.sessionID, workspace: lodyWorkspace)?.absoluteString {
                return "open \(shellEscape(deepLink))"
            }
            return "npx lody session list --json"
        }
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
