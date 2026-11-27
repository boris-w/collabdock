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

/// 执行后端类型（当前仅保留 Lody 编排层）
public enum ExecutionBackendKind: String, Codable, CaseIterable, Hashable, Sendable {
    case lody
}

/// 工作区定位与准备请求（由 `ReviewExecutionService` 交给选定后端处理）
public struct WorkspacePreparationRequest: Sendable {
    public let item: CollaborationItem
    public let plan: ExecutionPlan
    public let searchRoots: [String]
    public let preferredLocalPath: String?
    public let environment: EnvironmentSnapshot?

    public init(
        item: CollaborationItem,
        plan: ExecutionPlan,
        searchRoots: [String] = [],
        preferredLocalPath: String? = nil,
        environment: EnvironmentSnapshot? = nil
    ) {
        self.item = item
        self.plan = plan
        self.searchRoots = searchRoots
        self.preferredLocalPath = preferredLocalPath
        self.environment = environment
    }
}

/// 子进程原始执行输出快照（供各后端独立做结果解析、错误提取与用量组装）
public struct RawExecutionOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let sessionID: String?
    public let finalText: String?
    public let outputFileText: String?
    public let usage: AgentUsageMetrics?
    public let durationSeconds: Double

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        sessionID: String? = nil,
        finalText: String? = nil,
        outputFileText: String? = nil,
        usage: AgentUsageMetrics? = nil,
        durationSeconds: Double = 0
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.sessionID = sessionID
        self.finalText = finalText
        self.outputFileText = outputFileText
        self.usage = usage
        self.durationSeconds = durationSeconds
    }
}

/// 统一执行后端协议：负责工作区定位、命令构造、启动执行、结果解析、会话句柄与续聊命令
public protocol ExecutionBackend: Sendable {
    var kind: ExecutionBackendKind { get }

    /// 1. 定位并准备本次运行所需的上下文/工作区
    func prepareWorkspace(
        for request: WorkspacePreparationRequest,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> PreparedWorkspaceContext

    /// 2. 根据已构造的安全 Prompt 生成最终 CLI 命令规格（含工作目录）
    func buildCommand(
        for request: AgentRunRequest,
        prompt: String
    ) throws -> AgentCommandSpec

    /// 3. 启动子进程并流式消费输出、剥离敏感环境变量、完成解析与句柄构建
    func execute(
        _ request: AgentRunRequest,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> AgentRunResult

    /// 4. 解析原始子进程输出（处理错误码提取、后台派发与用量补全）
    func parseResult(
        _ raw: RawExecutionOutput,
        for request: AgentRunRequest
    ) throws -> AgentRunResult

    /// 5. 构造持久化会话句柄（兼顾首次运行与续聊原会话）
    func makeSessionHandle(
        sessionID: String?,
        for request: AgentRunRequest
    ) -> AgentSessionHandle?

    /// 6. 生成安全转义的终端接管 / 续聊命令
    func resumeShellCommand(for handle: AgentSessionHandle) -> String
}

public extension ExecutionBackend {
    static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
