import Foundation

/// A user's answer to a pending permission request (`PermissionFooter.tsx` and
/// `ExitPlanToolView.tsx` button mapping).
public enum PermissionReply: Sendable, Equatable {
    case allow
    /// Claude: don't ask again for this tool. Decision agents: approve for the session.
    case allowForSession
    /// Claude: accept every edit for the rest of the session.
    case allowAllEdits
    /// Claude: allow a shell command family for the session (`Bash(git status:*)`).
    case allowCommand(String)
    /// Codex: always allow this command, in its exec policy.
    case allowExecPolicy([String])
    /// Deny; Claude reads `reason` as feedback for its next step.
    case deny(reason: String?)
    /// Deny and stop the current turn.
    case stop
    /// Approve a plan (ExitPlanMode), optionally switching the session's permission mode.
    case approvePlan(mode: String?)
    /// Send a plan back, with what to change.
    case rejectPlan(feedback: String?)

    /// Every agent but Claude answers with `decision`s (`promptProtocol: 'codexDecision'`). An
    /// unknown agent is treated as Claude, the UI's default agent.
    static func usesDecisions(_ agentId: String?) -> Bool {
        agentId.map { $0 != "claude" } ?? false
    }

    func payload(requestId: String, tool: String, agentId: String?) -> JSONValue {
        let decisions = Self.usesDecisions(agentId)
        var body: [String: JSONValue] = ["id": .string(requestId)]
        switch self {
        case .allow:
            body["approved"] = true
            if decisions { body["decision"] = "approved" }
        case .allowForSession:
            body["approved"] = true
            if decisions {
                body["decision"] = "approved_for_session"
            } else {
                body["allowedTools"] = [.string(tool)]
                body["updatedPermissions"] = [Self.allowRule(tool)]
            }
        case .allowAllEdits:
            body["approved"] = true
            if decisions {
                body["decision"] = "approved"
            } else {
                body["mode"] = "acceptEdits"
                body["updatedPermissions"] = [Self.setMode("acceptEdits")]
            }
        case .allowCommand(let identifier):
            body["approved"] = true
            if decisions {
                body["decision"] = "approved_for_session"
            } else {
                body["allowedTools"] = [.string(identifier)]
                body["updatedPermissions"] = [Self.allowRule(identifier)]
            }
        case .allowExecPolicy(let command):
            body["approved"] = true
            body["decision"] = "approved_execpolicy_amendment"
            body["execPolicyAmendment"] = ["command": .array(command.map(JSONValue.string))]
        case .deny(let reason):
            body["approved"] = false
            body["decision"] = "denied"
            if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty { body["reason"] = .string(reason) }
        case .stop:
            body["approved"] = false
            body["decision"] = agentId == "codex" ? "denied" : "abort"
        case .approvePlan(let mode):
            body["approved"] = true
            if let mode {
                body["mode"] = .string(mode)
                body["updatedPermissions"] = [Self.setMode(mode)]
            }
        case .rejectPlan(let feedback):
            body["approved"] = false
            if let feedback = feedback?.trimmingCharacters(in: .whitespacesAndNewlines), !feedback.isEmpty { body["reason"] = .string(feedback) }
        }
        return .object(body)
    }

    /// Whether the reply should be followed by the session `abort` RPC: Stop, except on Codex,
    /// which only denies (`stopHandling: 'denyOnly'`).
    func abortsTurn(agentId: String?) -> Bool {
        guard case .stop = self else { return false }
        return agentId != "codex"
    }

    /// `{type:'addRules'}` for a tool, `Name(spec)` split into its name and rule.
    private static func allowRule(_ identifier: String) -> JSONValue {
        var rule: [String: JSONValue] = ["toolName": .string(identifier)]
        if let open = identifier.firstIndex(of: "("), identifier.hasSuffix(")"), open > identifier.startIndex {
            rule["toolName"] = .string(String(identifier[..<open]))
            let spec = identifier[identifier.index(after: open)..<identifier.index(before: identifier.endIndex)]
            if !spec.isEmpty { rule["ruleContent"] = .string(String(spec)) }
        }
        return ["type": "addRules", "rules": [.object(rule)], "behavior": "allow", "destination": "session"]
    }

    private static func setMode(_ mode: String) -> JSONValue {
        ["type": "setMode", "mode": .string(mode), "destination": "session"]
    }
}

/// The answers a pending permission request offers (`PermissionFooter.tsx` gating).
public struct PermissionPrompt: Sendable, Equatable {
    public struct CommandGrant: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case subcommand, commandName }
        public let kind: Kind
        /// What it covers, shown to the user: `git status`, `git`.
        public let label: String
        /// The rule sent to the agent: `Bash(git status:*)`.
        public let identifier: String
        public var id: String { identifier }
    }

    public let agentId: String?
    public let tool: String
    public let input: JSONValue

    public init(agentId: String?, tool: String, input: JSONValue) {
        self.agentId = agentId
        self.tool = tool
        self.input = input
    }

    private var claude: Bool { !PermissionReply.usesDecisions(agentId) }
    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    private static let planTools: Set<String> = ["ExitPlanMode", "exit_plan_mode"]
    private static let shellTools: Set<String> = ["bash", "execute", "shell"]
    private static let subcommandTools: Set<String> = ["git", "npm", "yarn", "pnpm", "cargo", "docker", "kubectl", "gh", "brew"]

    /// ExitPlanMode gets its own review (approve, approve with a mode, request changes).
    public var isPlanReview: Bool { Self.planTools.contains(tool) }
    public var plan: String? { input["plan"]?.stringValue }

    /// Claude's "allow all edits during this session", on its file-editing tools.
    public var offersAllEdits: Bool { claude && Self.editTools.contains(tool) }

    /// Claude: "don't ask again for this tool". Decision agents: "don't ask again this session".
    public var offersAlwaysForTool: Bool {
        if isPlanReview { return false }
        return !claude || !Self.editTools.contains(tool)
    }

    /// Claude only: the CLI passes the reason to Claude as its feedback; others ignore it.
    public var acceptsDenialFeedback: Bool { claude }

    /// Claude shell grants for one simple command: its subcommand (`git status`) for well-known
    /// tools, and the command name (`git`).
    public var commandGrants: [CommandGrant] {
        guard claude, Self.shellTools.contains(tool.lowercased()), let command = Self.shellCommand(input),
              Self.isBroadGrantEligible(command) else { return [] }
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = parts.first else { return [] }
        var grants: [CommandGrant] = []
        if parts.count > 1, !parts[1].hasPrefix("-"), Self.subcommandTools.contains(name) {
            let label = "\(name) \(parts[1])"
            grants.append(CommandGrant(kind: .subcommand, label: label, identifier: "\(tool)(\(label):*)"))
        }
        grants.append(CommandGrant(kind: .commandName, label: name, identifier: "\(tool)(\(name):*)"))
        return grants
    }

    /// Codex's proposed exec-policy rule, when it offers "always allow".
    public var execPolicyCommand: [String]? {
        guard agentId == "codex" else { return nil }
        let proposal = input["proposedExecpolicyAmendment"] ?? input["proposed_execpolicy_amendment"]
        let command = proposal?.arrayValue?.compactMap(\.stringValue) ?? []
        return command.isEmpty || command.count != proposal?.arrayValue?.count ? nil : command
    }

    /// One simple command: no leading assignment or `unset`, no chaining, pipes, redirects or
    /// substitutions (`isBroadShellGrantEligible`).
    static func isBroadGrantEligible(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil { return false }
        if trimmed == "unset" || trimmed.hasPrefix("unset ") || trimmed.hasPrefix("unset\t") { return false }
        if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>`\r\n")) != nil { return false }
        return !trimmed.contains("$(")
    }

    /// The command a shell tool runs (`extractShellCommand`): `{command}`, `{cmd}`, or an argv
    /// array, without a `bash -lc` / `zsh -lc` wrapper.
    public static func shellCommand(_ input: JSONValue) -> String? {
        if let argv = stringArray(input) { return unwrap(argv) }
        for key in ["command", "cmd"] {
            if let text = input[key]?.stringValue {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if let argv = input[key].flatMap(stringArray) {
                return unwrap(argv)
            }
        }
        return nil
    }

    private static func stringArray(_ value: JSONValue) -> [String]? {
        guard let items = value.arrayValue, !items.isEmpty else { return nil }
        let strings = items.compactMap(\.stringValue)
        return strings.count == items.count ? strings : nil
    }

    private static func unwrap(_ argv: [String]) -> String {
        if argv.count >= 3, ["bash", "/bin/bash", "zsh", "/bin/zsh"].contains(argv[0]), argv[1] == "-lc" { return argv[2] }
        return argv.joined(separator: " ")
    }
}
