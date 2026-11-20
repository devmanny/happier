import Foundation

/// Multi-message selection (`TranscriptSelectionToolbar`, `formatSelectedMessagesForClipboard.ts`).
public enum MessageSelection {
    /// User messages and agent replies with text; thinking and tools are not selectable.
    public static func isSelectable(_ item: ChatItem) -> Bool {
        switch item {
        case .userText(let message): message.sessionNotice == nil && !message.text.isEmpty
        case .agentText(let message): !message.isThinking && !message.text.isEmpty
        default: false
        }
    }

    private enum Speaker: Hashable {
        case user, agent, session(String)

        func label(agentName: String) -> String {
            switch self {
            case .user: String(localized: "You")
            case .agent: agentName
            case .session(let id): "\(String(localized: "Session")) \(id)"
            }
        }
    }

    /// Selected messages in order: plain for one speaker, labelled when speakers differ.
    public static func clipboardText(_ items: [ChatItem], agentName: String) -> String {
        let entries: [(speaker: Speaker, text: String)] = items.compactMap { item in
            switch item {
            case .userText(let message) where message.sessionNotice == nil:
                (message.sessionMessageOrigin.map { .session($0.senderSessionId) } ?? .user, message.text)
            case .agentText(let message) where !message.isThinking: (.agent, message.text)
            default: nil
            }
        }
        let mixed = Set(entries.map(\.speaker)).count > 1
        return entries.map { entry in
            mixed ? "**\(entry.speaker.label(agentName: agentName)):**\n\n\(entry.text)" : entry.text
        }.joined(separator: "\n\n")
    }
}
