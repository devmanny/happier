import Foundation

/// Multi-message selection (`TranscriptSelectionToolbar`, `formatSelectedMessagesForClipboard.ts`).
public enum MessageSelection {
    /// User messages and agent replies with text; thinking and tools are not selectable.
    public static func isSelectable(_ item: ChatItem) -> Bool {
        switch item {
        case .userText(let message): !message.text.isEmpty
        case .agentText(let message): !message.isThinking && !message.text.isEmpty
        default: false
        }
    }

    /// Selected messages in transcript order: plain when one role, `**Role:**`-labelled when mixed.
    public static func clipboardText(_ items: [ChatItem], agentName: String) -> String {
        let entries: [(user: Bool, text: String)] = items.compactMap { item in
            switch item {
            case .userText(let message): (true, message.text)
            case .agentText(let message) where !message.isThinking: (false, message.text)
            default: nil
            }
        }
        let mixed = Set(entries.map(\.user)).count > 1
        return entries.map { entry in
            mixed ? "**\(entry.user ? String(localized: "You") : agentName):**\n\n\(entry.text)" : entry.text
        }.joined(separator: "\n\n")
    }
}
