import Foundation

/// Files the agent put in front of the user with Claude Code's `SendUserFile` tool (2.1.322):
/// input `{files, caption?, status: normal|proactive, display?: render|attach}`, structured result
/// `{caption?, display?, attachments: [{path, size, isImage, media_type?, …}]}`. They stay on the
/// session's computer; the conversation fetches them through the attachment download route.
public struct SentFiles: Equatable, Sendable {
    public let caption: String?
    public let files: [MessageAttachment]
    /// `display: "attach"`: the agent asked for a download card, not an inline preview.
    public let attachOnly: Bool

    /// Nil for other tools, for a send waiting for approval (its approval card asks first) and for
    /// one that failed or was refused (nothing reached the user; it stays an ordinary failed step).
    /// `status` changes nothing here: `proactive` only says the agent sent it unasked.
    public init?(_ tool: ToolCall) {
        guard tool.name == "SendUserFile", tool.state != .error, tool.permission?.status != .pending else { return nil }
        let input = tool.input
        let result = tool.structuredResult
        // The result has each file as the computer resolved it, with its size and type; until it
        // arrives, the paths the agent asked to send (one path may come as a string).
        let resolved = (result?["attachments"]?.arrayValue ?? []).compactMap { entry -> MessageAttachment? in
            guard let path = Self.nonblank(entry["path"]) else { return nil }
            return Self.file(path, mimeType: Self.nonblank(entry["media_type"]), sizeBytes: entry["size"]?.intValue, sentBy: tool.id)
        }
        let requested = (input["files"]?.arrayValue ?? input["files"].map { [$0] } ?? []).compactMap(Self.nonblank)
        let files = resolved.isEmpty ? requested.map { Self.file($0, mimeType: nil, sizeBytes: nil, sentBy: tool.id) } : resolved
        guard !files.isEmpty else { return nil }
        self.files = files
        caption = Self.nonblank(result?["caption"]) ?? Self.nonblank(input["caption"])
        attachOnly = (result?["display"] ?? input["display"])?.stringValue == "attach"
    }

    private static func file(_ path: String, mimeType: String?, sizeBytes: Int?, sentBy toolId: String) -> MessageAttachment {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        return MessageAttachment(name: name, path: path, mimeType: mimeType, sizeBytes: sizeBytes, revision: toolId)
    }

    private static func nonblank(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

public extension ToolCall {
    /// The files this call sent the user, when it is a `SendUserFile` that reached them.
    var sentFiles: SentFiles? { SentFiles(self) }
}
