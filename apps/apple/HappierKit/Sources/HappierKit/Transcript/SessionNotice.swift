import Foundation

/// Presentation of the existing CLI lineage text, not a new transport role or proof of authorship.
/// Only complete messages emitted by `session/lineage/childSessionNotice.ts` are recognized.
public struct SessionNotice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case parentLinked, parentDetached, childAdopted, childReleased
        case turnCompleted, turnFailed, blockedPermission, blockedQuestion, stopped
    }

    public let kind: Kind
    public let relatedSessionId: String?
    public let relatedSessionTitle: String?
    public let detail: String?
    public let originalText: String

    private static let childHeader = "[Happier automatic notice — child session event, not a user message]"
    private static let parentHeader = "[Happier automatic notice — session nesting changed, not a user message]"
    private static let guidance = "Communicate only with your direct parent and your direct children; never relay to, or contact, grandparents or grandchildren."

    public static func parse(_ text: String) -> SessionNotice? {
        let child = text.hasPrefix(childHeader + "\n")
        guard child || text.hasPrefix(parentHeader + "\n"), text.hasSuffix("\n" + guidance) else { return nil }
        let header = child ? childHeader : parentHeader
        let body = String(text.dropFirst(header.count + 1).dropLast(guidance.count + 1))
        return child ? parseChild(body, original: text) : parseLink(body, original: text)
    }

    private static func parseChild(_ body: String, original: String) -> SessionNotice? {
        guard let newline = body.lastIndex(of: "\n") else { return nil }
        let reply = String(body[body.index(after: newline)...])
        guard let fields = captures(#"\AChild session: ([\s\S]+?)\nEvent: ([\s\S]+)\z"#, in: String(body[..<newline])),
              let identity = identity(fields[0]) else { return nil }
        let event = fields[1]
        let kind: Kind
        let detail: String?
        let completed = "finished its turn and is now idle, waiting for input"
        if event == completed {
            kind = .turnCompleted; detail = nil
        } else if event.hasPrefix(completed + "\nLast assistant message (excerpt):\n") {
            let excerpt = String(event.dropFirst((completed + "\nLast assistant message (excerpt):\n").count))
            guard !excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            kind = .turnCompleted; detail = excerpt
        } else if event == "stopped with an error" {
            kind = .turnFailed; detail = nil
        } else if event.hasPrefix("stopped with an error: ") {
            let error = String(event.dropFirst("stopped with an error: ".count))
            guard !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            kind = .turnFailed; detail = error
        } else if let fields = captures(#"\Astopped with an error \(([\s\S]+)\)\z"#, in: event) {
            kind = .turnFailed; detail = fields[0]
        } else if let fields = captures(#"\Ablocked — waiting for (permission approval|an answer to a question) \(tool: ([^\n]+)\)(?:\nPending request:\n([\s\S]+))?\z"#, in: event) {
            guard !fields[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            kind = fields[0] == "permission approval" ? .blockedPermission : .blockedQuestion
            detail = "Tool: " + fields[1] + (fields[2].isEmpty ? "" : "\n" + fields[2])
        } else if let fields = captures(#"\Astopped \(([\s\S]+)\)\z"#, in: event) {
            kind = .stopped; detail = fields[0]
        } else { return nil }
        let command = "happier session send \(identity.id) \"<your message>\""
        let expectedReply: String
        switch kind {
        case .blockedPermission, .blockedQuestion:
            expectedReply = "Approve or answer it from the Happier app, or send guidance with: " + command
        case .stopped: expectedReply = "Sending it a message resumes it: " + command
        case .turnFailed where event.hasPrefix("stopped with an error ("):
            expectedReply = "Sending it a message resumes it: " + command
        default: expectedReply = "To reply to it, run: " + command
        }
        guard reply == expectedReply else { return nil }
        return SessionNotice(kind: kind, relatedSessionId: identity.id, relatedSessionTitle: identity.title,
                             detail: detail, originalText: original)
    }

    private static func parseLink(_ body: String, original: String) -> SessionNotice? {
        if body == "You no longer have a parent session; you are at the top level and your events are not reported to any session." {
            return SessionNotice(kind: .parentDetached, relatedSessionId: nil, relatedSessionTitle: nil, detail: nil, originalText: original)
        }
        if let fields = captures(#"\AYou are now a direct child of session ([^\s]+)\. Your turn-complete, blocked, failed and stopped events are reported to it automatically; to talk to it yourself, run: happier session send ([^\s]+) "<your message>"\z"#, in: body), fields[0] == fields[1] {
            return SessionNotice(kind: .parentLinked, relatedSessionId: fields[0], relatedSessionTitle: nil, detail: nil, originalText: original)
        }
        if let fields = captures(#"\A([\s\S]+) is no longer your direct child session; it will not report to you anymore\.\z"#, in: body),
           let identity = identity(fields[0]) {
            return SessionNotice(kind: .childReleased, relatedSessionId: identity.id, relatedSessionTitle: identity.title, detail: nil, originalText: original)
        }
        if let fields = captures(#"\AYou have a new direct child session: ([\s\S]+?)\n((?:Folder: [^\n]+\n)?(?:Machine: [^\n]+\n)?)Current state: (blocked, waiting for a permission approval or an answer|working on a turn|ready, idle and waiting for input)\nIt will report to you when it finishes a turn, blocks, fails or stops\. To talk to it, run: happier session send ([^\s]+) "<your message>"\z"#, in: body),
           let identity = identity(fields[0]), identity.id == fields[3] {
            return SessionNotice(kind: .childAdopted, relatedSessionId: identity.id, relatedSessionTitle: identity.title,
                                 detail: fields[1] + "Current state: " + fields[2], originalText: original)
        }
        return nil
    }

    private static func identity(_ text: String) -> (id: String, title: String?)? {
        if let fields = captures(#"\A"([\s\S]+)" \(id: ([^\s]+)\)\z"#, in: text) {
            guard !fields[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (fields[1], fields[0])
        }
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !text.hasPrefix("\"") else { return nil }
        return (text, nil)
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
