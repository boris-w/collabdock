import Foundation

/// 后端无关的单次 AI 执行请求对象：收拢原 `AgentSessionRunner.run` 的多参数列表，且不包含任何 Lody 专属字段
public struct AgentRunRequest: Sendable {
    public let item: CollaborationItem
    public let plan: ExecutionPlan
    public let preset: TaskPreset
    public let workspace: PreparedWorkspaceContext
    public let environment: EnvironmentSnapshot?
    public let injectPresetPrompt: Bool
    public let cancellationToken: ProcessCancellationToken

    public init(
        item: CollaborationItem,
        plan: ExecutionPlan,
        preset: TaskPreset,
        workspace: PreparedWorkspaceContext,
        environment: EnvironmentSnapshot? = nil,
        injectPresetPrompt: Bool = true,
        cancellationToken: ProcessCancellationToken = ProcessCancellationToken()
    ) {
        self.item = item
        self.plan = plan
        self.preset = preset
        self.workspace = workspace
        self.environment = environment
        self.injectPresetPrompt = injectPresetPrompt
        self.cancellationToken = cancellationToken
    }
}
