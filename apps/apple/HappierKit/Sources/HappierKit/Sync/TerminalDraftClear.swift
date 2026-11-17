import Foundation

/// Clear Terminal Draft (`session.terminalComposer.clear`): asks the session's runner to empty
/// Claude's terminal composer, where text it didn't write holds queued messages back
/// (`terminal_composer_draft`). The runner presses only Esc, refuses while Claude is working or
/// asking something, and sends the held messages itself once the composer is empty.
public enum TerminalDraftClear {
    public enum Outcome: Equatable, Sendable {
        case cleared
        /// The composer was already empty; the runner still sends what it held.
        case nothingToClear
        /// Claude is generating: Esc would stop it.
        case working
        /// A permission prompt, menu or other dialog is open.
        case dialogOpen
        case notSafe
        /// Esc didn't empty the composer.
        case notCleared
        /// No runner or live terminal answers for the session.
        case unreachable
        /// The runner (or its terminal) can't do this.
        case unsupported
        case failed(String)

        /// What to tell the user; nil when the cleared draft speaks for itself.
        public var message: String? {
            switch self {
            case .cleared: nil
            case .nothingToClear: String(localized: "Claude's composer is already empty. Your queued messages will go out now; if one stays blocked, tap Retry on it.")
            case .working: String(localized: "Claude is working in the terminal, and Esc would stop it. Try again when it finishes.")
            case .dialogOpen: String(localized: "Claude is showing a question or a menu in the terminal. Answer it first (permission requests also appear here), then try again.")
            case .notSafe: String(localized: "The terminal can't be cleared safely right now. Try again in a moment.")
            case .notCleared: String(localized: "Claude didn't clear the draft. Try again, or press Esc twice in the terminal on your computer.")
            case .unreachable: String(localized: "Happier can't reach this session's terminal right now.")
            case .unsupported: String(localized: "Happier on this computer can't clear the terminal for this session. Clear the draft at the computer, or update Happier there.")
            case .failed(let message): message
            }
        }
    }

    /// The runner's answer (`SessionTerminalComposerClearResultV1`), read from its wire `status`
    /// only; a status this app doesn't know reads as not cleared.
    public static func outcome(_ result: JSONValue) -> Outcome {
        switch result["status"]?.stringValue {
        case "cleared": .cleared
        case "already_empty": .nothingToClear
        case "generating": .working
        case "dialog_open": .dialogOpen
        case "not_safe": .notSafe
        case "no_live_terminal", "host_dead": .unreachable
        // The terminal can't show its screen to the runner, so it can't check what Esc would hit.
        case "unsupported", "capture_unavailable": .unsupported
        default: .notCleared
        }
    }

    /// The relay couldn't deliver the call or bring back an answer.
    public static func outcome(error: Error) -> Outcome {
        switch (error as? HappierStore.RPCError)?.code {
        case RPCErrorCodes.noConnectedTarget: .unreachable
        case RPCErrorCodes.notImplemented: .unsupported
        default: .failed(UserFacingError.message(for: error))
        }
    }
}

extension Session {
    /// The runner can clear its terminal composer (`terminalComposerClearSupported`, published by
    /// the unified Claude terminal runner); missing on older runners and other agents.
    public var terminalDraftClearSupported: Bool {
        agentState["capabilities"]?["terminalComposerClearSupported"]?.boolValue == true
    }
}
