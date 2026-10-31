import Testing
@testable import HappierKit

/// Payloads for the `<sid>:permission` RPC (`PermissionFooter.tsx`, `ExitPlanToolView.tsx`,
/// `sessionPermissionRpc.ts`).
@Suite struct PermissionPayloadTests {
    @Test func claudeStyleDecisions() {
        #expect(PermissionReply.allow.payload(requestId: "r", tool: "Bash", agentId: "claude") == ["id": "r", "approved": true])
        #expect(PermissionReply.allowForSession.payload(requestId: "r", tool: "WebFetch", agentId: "claude") == [
            "id": "r", "approved": true, "allowedTools": ["WebFetch"],
            "updatedPermissions": [["type": "addRules", "rules": [["toolName": "WebFetch"]], "behavior": "allow", "destination": "session"]],
        ])
        #expect(PermissionReply.allowAllEdits.payload(requestId: "r", tool: "Edit", agentId: "claude") == [
            "id": "r", "approved": true, "mode": "acceptEdits",
            "updatedPermissions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"]],
        ])
    }

    @Test func claudeCommandGrantsBecomeSessionRules() {
        #expect(PermissionReply.allowCommand("Bash(git status:*)").payload(requestId: "r", tool: "Bash", agentId: "claude") == [
            "id": "r", "approved": true, "allowedTools": ["Bash(git status:*)"],
            "updatedPermissions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "git status:*"]],
                                    "behavior": "allow", "destination": "session"]],
        ])
    }

    @Test func denyIsNeverAnImplicitAbort() {
        // The CLI treats `approved:false` without a decision as abort.
        #expect(PermissionReply.deny(reason: nil).payload(requestId: "r", tool: "Bash", agentId: "claude")
            == ["id": "r", "approved": false, "decision": "denied"])
        #expect(PermissionReply.deny(reason: "use pnpm").payload(requestId: "r", tool: "Bash", agentId: "claude")
            == ["id": "r", "approved": false, "decision": "denied", "reason": "use pnpm"])
        #expect(PermissionReply.stop.payload(requestId: "r", tool: "Bash", agentId: "claude")
            == ["id": "r", "approved": false, "decision": "abort"])
    }

    @Test func codexStyleAgentsUseDecisions() {
        #expect(PermissionReply.allow.payload(requestId: "r", tool: "Bash", agentId: "codex")
            == ["id": "r", "approved": true, "decision": "approved"])
        #expect(PermissionReply.allowForSession.payload(requestId: "r", tool: "Bash", agentId: "gemini")
            == ["id": "r", "approved": true, "decision": "approved_for_session"])
        #expect(PermissionReply.allowForSession.payload(requestId: "r", tool: "read", agentId: "opencode")
            == ["id": "r", "approved": true, "decision": "approved_for_session"])
        #expect(PermissionReply.allowExecPolicy(["npm", "test"]).payload(requestId: "r", tool: "CodexBash", agentId: "codex") == [
            "id": "r", "approved": true, "decision": "approved_execpolicy_amendment", "execPolicyAmendment": ["command": ["npm", "test"]],
        ])
    }

    /// Stop: Codex only denies (`stopHandling: 'denyOnly'`); every other agent aborts the turn.
    @Test func stopAbortsTheTurnExceptOnCodex() {
        #expect(PermissionReply.stop.payload(requestId: "r", tool: "Bash", agentId: "codex")
            == ["id": "r", "approved": false, "decision": "denied"])
        #expect(!PermissionReply.stop.abortsTurn(agentId: "codex"))
        for agent in ["claude", "gemini", "kimi", "opencode"] {
            #expect(PermissionReply.stop.payload(requestId: "r", tool: "Bash", agentId: agent)
                == ["id": "r", "approved": false, "decision": "abort"])
            #expect(PermissionReply.stop.abortsTurn(agentId: agent))
        }
    }

    @Test func planReviewReplies() {
        #expect(PermissionReply.approvePlan(mode: nil).payload(requestId: "r", tool: "ExitPlanMode", agentId: "claude")
            == ["id": "r", "approved": true])
        #expect(PermissionReply.approvePlan(mode: "acceptEdits").payload(requestId: "r", tool: "ExitPlanMode", agentId: "claude") == [
            "id": "r", "approved": true, "mode": "acceptEdits",
            "updatedPermissions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"]],
        ])
        #expect(PermissionReply.rejectPlan(feedback: nil).payload(requestId: "r", tool: "ExitPlanMode", agentId: "claude")
            == ["id": "r", "approved": false])
        #expect(PermissionReply.rejectPlan(feedback: "  split it in two  ").payload(requestId: "r", tool: "ExitPlanMode", agentId: "claude")
            == ["id": "r", "approved": false, "reason": "split it in two"])
    }
}

/// Which answers a permission prompt offers (`PermissionFooter.tsx` button gating).
@Suite struct PermissionPromptTests {
    private func prompt(_ agent: String?, _ tool: String, _ input: JSONValue = .null) -> PermissionPrompt {
        PermissionPrompt(agentId: agent, tool: tool, input: input)
    }

    @Test func claudeEditToolsOfferAllEditsInsteadOfThisTool() {
        let edit = prompt("claude", "Edit", ["file_path": "/a"])
        #expect(edit.offersAllEdits && !edit.offersAlwaysForTool)
        let fetch = prompt("claude", "WebFetch", ["url": "https://x"])
        #expect(!fetch.offersAllEdits && fetch.offersAlwaysForTool)
        #expect(!prompt("claude", "ExitPlanMode").offersAlwaysForTool)
    }

    @Test func claudeShellCommandsOfferSubcommandAndCommandGrants() {
        let git = prompt("claude", "Bash", ["command": "git status --short"])
        #expect(git.commandGrants == [
            .init(kind: .subcommand, label: "git status", identifier: "Bash(git status:*)"),
            .init(kind: .commandName, label: "git", identifier: "Bash(git:*)"),
        ])
        // Only a known tool gets a subcommand grant; a flag isn't a subcommand.
        #expect(prompt("claude", "Bash", ["command": "ls -la"]).commandGrants == [.init(kind: .commandName, label: "ls", identifier: "Bash(ls:*)")])
        #expect(prompt("claude", "Bash", ["command": "git -C x status"]).commandGrants.map(\.kind) == [.commandName])
    }

    @Test func compoundOrPrefixedCommandsGetNoBroadGrant() {
        for command in ["git add . && git commit", "cat a | wc", "echo $(id)", "FOO=1 make", "unset X; ls", "echo `id`", "a > b"] {
            #expect(prompt("claude", "Bash", ["command": .string(command)]).commandGrants.isEmpty, "\(command)")
        }
    }

    @Test func shellCommandsAreReadFromEveryInputShape() {
        #expect(PermissionPrompt.shellCommand(["command": ["bash", "-lc", "npm test"]]) == "npm test")
        #expect(PermissionPrompt.shellCommand(["command": ["npm", "run", "build"]]) == "npm run build")
        #expect(PermissionPrompt.shellCommand(["cmd": "make"]) == "make")
        #expect(PermissionPrompt.shellCommand(["/bin/zsh", "-lc", "pwd"]) == "pwd")
        #expect(PermissionPrompt.shellCommand(["path": "/x"]) == nil)
    }

    @Test func decisionAgentsGetSessionApprovalAndCodexItsExecPolicy() {
        let codex = prompt("codex", "CodexBash", ["command": ["npm", "test"], "proposedExecpolicyAmendment": ["npm", "test"]])
        #expect(codex.offersAlwaysForTool && !codex.offersAllEdits && codex.commandGrants.isEmpty)
        #expect(codex.execPolicyCommand == ["npm", "test"])
        #expect(prompt("codex", "CodexBash", ["proposed_execpolicy_amendment": ["ls"]]).execPolicyCommand == ["ls"])
        // Only Codex applies exec-policy amendments.
        #expect(prompt("gemini", "shell", ["proposedExecpolicyAmendment": ["ls"]]).execPolicyCommand == nil)
        #expect(prompt("gemini", "edit").offersAlwaysForTool && !prompt("gemini", "edit").offersAllEdits)
    }

    @Test func feedbackOnDenialOnlyReachesClaude() {
        #expect(prompt("claude", "Bash").acceptsDenialFeedback)
        #expect(!prompt("codex", "Bash").acceptsDenialFeedback)
    }

    @Test func planReviewIsForExitPlanMode() {
        #expect(prompt("claude", "ExitPlanMode", ["plan": "# Plan"]).isPlanReview)
        #expect(prompt("claude", "exit_plan_mode").isPlanReview)
        #expect(!prompt("claude", "Bash").isPlanReview)
        #expect(prompt("claude", "ExitPlanMode", ["plan": "# Plan"]).plan == "# Plan")
    }
}
