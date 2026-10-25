import Testing
@testable import HappierKit

/// Payloads for the `<sid>:permission` RPC (`PermissionFooter.tsx`, `sessionPermissionRpc.ts`).
@Suite struct PermissionPayloadTests {
    @Test func claudeStyleDecisions() {
        #expect(PermissionReply.allow.payload(requestId: "r", tool: "Bash", agentId: "claude") == ["id": "r", "approved": true])
        #expect(PermissionReply.allowForSession.payload(requestId: "r", tool: "Edit", agentId: "claude")
            == ["id": "r", "approved": true, "allowedTools": ["Edit"]])
        #expect(PermissionReply.allowAllEdits.payload(requestId: "r", tool: "Edit", agentId: "claude")
            == ["id": "r", "approved": true, "mode": "acceptEdits"])
    }

    @Test func denyIsNeverAnImplicitAbort() {
        // The CLI treats `approved:false` without a decision as abort.
        #expect(PermissionReply.deny(reason: nil).payload(requestId: "r", tool: "Bash", agentId: "claude")
            == ["id": "r", "approved": false, "decision": "denied"])
        #expect(PermissionReply.deny(reason: "use pnpm").payload(requestId: "r", tool: "Bash", agentId: "codex")
            == ["id": "r", "approved": false, "decision": "denied", "reason": "use pnpm"])
        #expect(PermissionReply.stop.payload(requestId: "r", tool: "Bash", agentId: "claude")
            == ["id": "r", "approved": false, "decision": "abort"])
    }

    @Test func codexStyleAgentsUseDecisions() {
        #expect(PermissionReply.allow.payload(requestId: "r", tool: "Bash", agentId: "codex")
            == ["id": "r", "approved": true, "decision": "approved"])
        #expect(PermissionReply.allowForSession.payload(requestId: "r", tool: "Bash", agentId: "gemini")
            == ["id": "r", "approved": true, "decision": "approved_for_session"])
        #expect(PermissionReply.stop.payload(requestId: "r", tool: "Bash", agentId: "codex")
            == ["id": "r", "approved": false, "decision": "denied"])
        #expect(!PermissionReply.stop.abortsTurn(agentId: "codex") && PermissionReply.stop.abortsTurn(agentId: "claude"))
    }
}
