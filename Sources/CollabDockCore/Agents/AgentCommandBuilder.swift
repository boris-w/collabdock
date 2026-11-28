import Foundation

public struct AgentCommandSpec: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: URL
    public let outputFilePath: URL?

    public init(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        outputFilePath: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.outputFilePath = outputFilePath
    }
}

/// Lody 后台会话命令与用户模板 Prompt 构造器（关联 REQ-007, REQ-008, REQ-014, ADR-007）
public struct AgentCommandBuilder: Sendable {
    public init() {}

    private static let placeholderRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\{\{([a-z_]+)\}\}"#, options: [])
    }()

    /// 渲染发给 Lody 的提示词：仅输出用户模板（含经校验的有限占位符），如有补充指令则空一行附在末尾
    public func buildPrompt(
        item: CollaborationItem,
        preset: TaskPreset,
        extraInstructions: String,
        previousReview: PreviousReviewContext? = nil,
        continuityMode: ReviewContinuityMode = .freshSessionFull,
        language: ResolvedLanguage? = nil
    ) -> String {
        let isFollowUp = previousReview != nil
            && (continuityMode == .continueSessionIncremental || continuityMode == .freshSessionIncremental)
        let kind: PromptTemplateKind = isFollowUp ? .followUp : .firstReview
        let resolvedLanguage = language ?? CoreL10n.currentLanguage
        let template = preset.effectiveTemplate(for: kind, language: resolvedLanguage)

        let repoValue: String
        let numberValue: String
        let headSHAValue: String
        if case .codeChange(let code) = item.payload {
            repoValue = Self.validatedSafeRepository(code.repository) ?? ""
            numberValue = String(code.number)
            headSHAValue = Self.validatedHexSHA(code.headSHA) ?? ""
        } else {
            repoValue = ""
            numberValue = ""
            headSHAValue = ""
        }
        let previousSHAValue = previousReview.flatMap { Self.validatedHexSHA($0.reviewedHeadSHA) } ?? ""

        let values: [String: String] = [
            "pr_url": item.url.absoluteString,
            "repo": repoValue,
            "number": numberValue,
            "head_sha": headSHAValue,
            "previous_sha": previousSHAValue
        ]

        let rendered = Self.renderTemplate(template, values: values)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if extra.isEmpty {
            return rendered
        }
        if rendered.isEmpty {
            return extra
        }
        return "\(rendered)\n\n\(extra)"
    }

    private static func renderTemplate(_ template: String, values: [String: String]) -> String {
        let nsTemplate = template as NSString
        let matches = placeholderRegex.matches(
            in: template,
            options: [],
            range: NSRange(location: 0, length: nsTemplate.length)
        )
        guard !matches.isEmpty else { return template }

        var result = ""
        var cursor = 0
        for match in matches {
            let fullRange = match.range(at: 0)
            let keyRange = match.range(at: 1)
            if fullRange.location > cursor {
                result += nsTemplate.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
            }
            let key = nsTemplate.substring(with: keyRange)
            if let replacement = values[key] {
                result += replacement
            } else {
                result += nsTemplate.substring(with: fullRange)
            }
            cursor = fullRange.location + fullRange.length
        }
        if cursor < nsTemplate.length {
            result += nsTemplate.substring(from: cursor)
        }
        return result
    }

    private static func isSafeRepoSegment(_ segment: Substring) -> Bool {
        guard !segment.isEmpty else { return false }
        return segment.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, // 0-9
                 0x41...0x5A, // A-Z
                 0x61...0x7A, // a-z
                 0x2E,        // .
                 0x5F,        // _
                 0x2D:        // -
                return true
            default:
                return false
            }
        }
    }

    private static func validatedSafeRepository(_ raw: String) -> String? {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              isSafeRepoSegment(parts[0]),
              isSafeRepoSegment(parts[1]) else {
            return nil
        }
        return raw
    }

    private static func validatedHexSHA(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let isHex = raw.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, // 0-9
                 0x41...0x46, // A-F
                 0x61...0x66: // a-f
                return true
            default:
                return false
            }
        }
        return isHex ? raw : nil
    }

    /// 构造 Lody 原生后台会话派发命令（`session create` 或续聊同 PR 原 Lody 会话 `session chat`，关联 ADR-007）
    public func buildBackgroundDispatchCommand(
        plan: ExecutionPlan,
        prompt: String,
        workspaceURL: URL,
        lodyConfig: LodyConfig = LodyConfig(),
        lodyAgentConfigOption: LodyAgentConfigOption? = nil,
        lodyWorkspaceTarget: LodyWorkspaceTarget? = nil,
        sessionTitle: String? = nil,
        repositoryFullName: String? = nil,
        lodyUseNPXFallback: Bool = false,
        executableOverride: String? = nil
    ) -> AgentCommandSpec {
        buildLodySessionCommand(
            plan: plan,
            prompt: prompt,
            workspaceURL: workspaceURL,
            lodyConfig: lodyConfig,
            lodyAgentConfigOption: lodyAgentConfigOption,
            lodyWorkspaceTarget: lodyWorkspaceTarget,
            sessionTitle: sessionTitle,
            repositoryFullName: repositoryFullName,
            useNPXFallback: lodyUseNPXFallback,
            executableOverride: executableOverride
        )
    }

    private func buildLodySessionCommand(
        plan: ExecutionPlan,
        prompt: String,
        workspaceURL: URL,
        lodyConfig: LodyConfig,
        lodyAgentConfigOption: LodyAgentConfigOption?,
        lodyWorkspaceTarget: LodyWorkspaceTarget?,
        sessionTitle: String?,
        repositoryFullName: String?,
        useNPXFallback: Bool,
        executableOverride: String?
    ) -> AgentCommandSpec {
        let useNPX = useNPXFallback || (executableOverride?.hasSuffix("/npx") == true)
        let executable: String
        if useNPX {
            executable = (executableOverride?.hasSuffix("/npx") == true) ? executableOverride! : "npx"
        } else {
            executable = executableOverride ?? "lody"
        }
        var args: [String] = []
        if useNPX {
            // 非交互子进程必须传 -y 并钉住 lody@latest，防止复用 ~/.npm/_npx 中陈旧的 next/staging 预发布缓存
            args.append(contentsOf: ["-y", "lody@latest"])
        }

        // 复审续聊：仅对同 PR 原 Lody 会话发 `lody session chat <sessionId> <prompt>`，绝不把外来引擎的 sessionID 发给 Lody
        if let resumeSessionID = resolvableResumeSessionID(for: plan) {
            args.append(contentsOf: ["session", "chat", "--json"])

            let ws = lodyConfig.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ws.isEmpty {
                args.append(contentsOf: ["--workspace", ws])
            }

            let chosenModel = plan.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !chosenModel.isEmpty && chosenModel != "default" {
                args.append(contentsOf: ["--model", chosenModel])
            }

            if let modeID = resolvedLodyMode(plan: plan, agentOption: lodyAgentConfigOption) {
                args.append(contentsOf: ["--mode", modeID])
            }

            if let effortKey = lodyAgentConfigOption?.effortOptionKey, !effortKey.isEmpty {
                let allowed = lodyAgentConfigOption?.reasoningEffortValues ?? []
                if allowed.isEmpty || allowed.contains(plan.effort.rawValue) {
                    args.append(contentsOf: ["--config-option", "\(effortKey)=\(plan.effort.rawValue)"])
                }
            }

            args.append(resumeSessionID)
            args.append(prompt)
            return AgentCommandSpec(
                executable: executable,
                arguments: args,
                workingDirectory: workspaceURL
            )
        }

        args.append(contentsOf: ["session", "create", "--json"])

        let ws = lodyConfig.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ws.isEmpty {
            args.append(contentsOf: ["--workspace", ws])
        }

        let planConfig = (plan.lodyAgentConfig ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveConfig = (planConfig.isEmpty || planConfig == "default")
            ? lodyConfig.defaultAgentConfig.trimmingCharacters(in: .whitespacesAndNewlines)
            : planConfig
        if !effectiveConfig.isEmpty && effectiveConfig != "default" {
            args.append(contentsOf: ["--agent-config", effectiveConfig])
        }

        let chosenModel = plan.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chosenModel.isEmpty && chosenModel != "default" {
            args.append(contentsOf: ["--model", chosenModel])
        }

        if let modeID = resolvedLodyMode(plan: plan, agentOption: lodyAgentConfigOption) {
            args.append(contentsOf: ["--mode", modeID])
        }

        if let effortKey = lodyAgentConfigOption?.effortOptionKey, !effortKey.isEmpty {
            let allowed = lodyAgentConfigOption?.reasoningEffortValues ?? []
            if allowed.isEmpty || allowed.contains(plan.effort.rawValue) {
                args.append(contentsOf: ["--config-option", "\(effortKey)=\(plan.effort.rawValue)"])
            }
        }

        if let title = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            args.append(contentsOf: ["--title", String(title.prefix(120))])
        }

        if let target = lodyWorkspaceTarget {
            switch target {
            case .localProject(let idOrPath, let useWorktree, let branch):
                args.append(contentsOf: ["--local-project", idOrPath])
                if useWorktree {
                    args.append("--worktree")
                    if let branch, !branch.isEmpty {
                        args.append(contentsOf: ["--branch", branch])
                    }
                }
            case .linkedGitHubRepo(let fullName, let branch):
                args.append(contentsOf: ["--repo", fullName])
                if let branch, !branch.isEmpty {
                    args.append(contentsOf: ["--branch", branch])
                }
            case .preparedLocalPath(let path):
                args.append(contentsOf: ["--local-project", path])
            }
        } else if lodyConfig.useLodyWorktree, let repo = repositoryFullName, !repo.isEmpty {
            args.append(contentsOf: ["--repo", repo])
        }

        args.append(prompt)
        return AgentCommandSpec(
            executable: executable,
            arguments: args,
            workingDirectory: workspaceURL
        )
    }

    private func resolvedLodyMode(
        plan: ExecutionPlan,
        agentOption: LodyAgentConfigOption?
    ) -> String? {
        let trimmed = plan.mode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            if trimmed == "__agent_default__" {
                return nil
            }
            return trimmed
        }
        if plan.sandboxPolicy == .readOnly,
           let modeID = agentOption?.readOnlyModeID, !modeID.isEmpty {
            return modeID
        }
        return nil
    }

    private func resolvableResumeSessionID(for plan: ExecutionPlan) -> String? {
        guard plan.continuityMode == .continueSessionIncremental,
              let prev = plan.previousReview,
              prev.engine == .lody,
              let sid = prev.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sid.isEmpty else {
            return nil
        }
        return sid
    }
}
