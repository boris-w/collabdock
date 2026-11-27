import Foundation
import Testing
@testable import CollabDockCore

@Suite("DiffLineValidator & ConnectorCatalog Tests [REQ-009][ADR-005]")
struct DiffLineValidatorTests {
    let validator = DiffLineValidator()

    @Test("Parses valid LEFT/RIGHT diff lines and downgrades out-of-hunk comments")
    func partitionsInlineAndFallbackComments() {
        let sampleDiff = """
        diff --git a/Sources/Auth.swift b/Sources/Auth.swift
        index 1111111..2222222 100644
        --- a/Sources/Auth.swift
        +++ b/Sources/Auth.swift
        @@ -10,4 +10,5 @@ func verify() {
             let header = request.header
        -    let token = parseLegacy(header)
        +    guard let token = parseJWKS(header) else {
        +        return nil
        +    }
             return token
        """

        let validMap = validator.parseValidLines(from: sampleDiff)
        let comments = [
            CodeInlineComment(
                path: "Sources/Auth.swift",
                line: 12,
                side: .right,
                severity: .warning,
                title: "Valid line comment",
                body: "Inside hunk"
            ),
            CodeInlineComment(
                path: "Sources/Auth.swift",
                line: 99,
                side: .right,
                severity: .nit,
                title: "Out-of-range comment",
                body: "Should fallback to summary"
            )
        ]

        let partitioned = validator.partition(comments: comments, validLinesByFile: validMap)
        #expect(partitioned.validInlineComments.count == 1)
        #expect(partitioned.fallbackSummaryComments.count == 1)
    }

    @Test("ConnectorCatalog negotiates platform-appropriate delivery modes")
    func connectorCapabilitiesNegotiation() {
        let ghCaps = ConnectorCatalog.capabilities(for: .github)
        #expect(ghCaps.isImplementedInV1 == true)
        #expect(ghCaps.defaultDeliveryMode == .platformDraft)
        #expect(ghCaps.requiresGitWorktree == true)

        let feishuCaps = ConnectorCatalog.capabilities(for: .feishu)
        #expect(feishuCaps.defaultDeliveryMode == .localDraftOnly)
        #expect(feishuCaps.requiresGitWorktree == false)
        #expect(!feishuCaps.supportedDeliveryModes.contains(.platformDraft))
    }
}
