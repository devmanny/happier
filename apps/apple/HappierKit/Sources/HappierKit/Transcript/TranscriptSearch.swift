import Foundation

/// Search inside the open conversation: the messages you and the agent wrote (not its thinking
/// or tool steps), ignoring case and accents. The transcript is end-to-end encrypted, so the
/// search runs here, over what has been loaded.
public enum TranscriptSearch {
    /// Ids of the matching messages, oldest first.
    public static func matches(in items: [ChatItem], query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return items.compactMap { item -> String? in
            let text: String? = switch item {
            case .userText(let user): user.text
            case .agentText(let agent): agent.isThinking ? nil : agent.text
            case .toolCall, .event: nil
            }
            guard let text, text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return nil }
            return item.id
        }
    }
}
