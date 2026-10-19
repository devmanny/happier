import Foundation

/// Raw record → content blocks (`apps/ui/sources/sync/typesRaw/normalize.ts`).
enum Normalizer {
    enum Block: Equatable {
        case userText(String, attachments: [String])
        case text(String, thinking: Bool)
        case toolCall(id: String, name: String, input: JSONValue, title: String?)
        /// `append` streams terminal output into an existing result.
        case toolResult(id: String, content: JSONValue, isError: Bool, append: Bool)
        case event(kind: String, data: JSONValue)
    }

    static func blocks(for record: JSONValue) -> [Block] {
        let meta = record["meta"]
        if meta?["sidechainId"]?.stringValue != nil { return [] }
        switch record["role"]?.stringValue {
        case "user":
            if meta?["happier"]?["kind"]?.stringValue == "tool-answer-delivery.v1" { return [] }
            guard let text = record["content"]?["text"]?.stringValue else { return [] }
            let attachments = meta?["happier"]?["kind"]?.stringValue == "attachments.v1"
                ? (meta?["happier"]?["payload"]?["attachments"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
                : []
            return [.userText(meta?["displayText"]?.stringValue ?? text, attachments: attachments)]
        case "agent":
            guard let content = record["content"] else { return [] }
            switch content["type"]?.stringValue {
            case "output": return output(content["data"] ?? .null)
            case "event": return event(content["data"] ?? .null)
            case "codex", "acp": return providerData(content["data"] ?? .null)
            default: return []
            }
        default:
            return []
        }
    }

    // MARK: Claude JSONL output

    private static func output(_ data: JSONValue) -> [Block] {
        if data["isSidechain"]?.boolValue == true || data["isMeta"]?.boolValue == true || data["isCompactSummary"]?.boolValue == true {
            return []
        }
        if data["parent_tool_use_id"]?.stringValue != nil { return [] }
        let content = data["message"]?["content"]
        switch data["type"]?.stringValue {
        case "assistant":
            if let text = content?.stringValue { return [.text(text, thinking: false)] }
            return (content?.arrayValue ?? []).compactMap(contentBlock)
        case "user":
            if let text = content?.stringValue { return [.userText(text, attachments: [])] }
            return (content?.arrayValue ?? []).compactMap { block in
                guard ["tool_result", "tool-call-result"].contains(block["type"]?.stringValue ?? "") else { return nil }
                let id = block["tool_use_id"]?.stringValue ?? block["callId"]?.stringValue ?? ""
                return .toolResult(id: id, content: block["content"] ?? .null, isError: block["is_error"]?.boolValue ?? false, append: false)
            }
        default:
            return []
        }
    }

    private static func contentBlock(_ block: JSONValue) -> Block? {
        switch block["type"]?.stringValue {
        case "text":
            return block["text"]?.stringValue.map { .text($0, thinking: false) }
        case "thinking":
            return block["thinking"]?.stringValue.map { .text($0, thinking: true) }
        case "tool_use", "tool-call":
            let id = block["id"]?.stringValue ?? block["callId"]?.stringValue ?? ""
            let input = parsedInput(block["input"])
            return .toolCall(id: id, name: block["name"]?.stringValue ?? "tool", input: input, title: input["description"]?.stringValue)
        case "tool_result", "tool-call-result":
            let id = block["tool_use_id"]?.stringValue ?? block["callId"]?.stringValue ?? ""
            return .toolResult(id: id, content: block["content"] ?? .null, isError: block["is_error"]?.boolValue ?? false, append: false)
        default:
            return nil
        }
    }

    // MARK: Session events

    private static func event(_ data: JSONValue) -> [Block] {
        guard let kind = data["type"]?.stringValue else { return [] }
        switch kind {
        case "ready", "task-lifecycle", "terminal-composer-draft-blocked", "runtime-config-outcome": return []
        default: return [.event(kind: kind, data: data)]
        }
    }

    // MARK: Codex / ACP

    private static func providerData(_ data: JSONValue) -> [Block] {
        if data["sidechainId"]?.stringValue != nil { return [] }
        switch data["type"]?.stringValue {
        case "message", "reasoning":
            return data["message"]?.stringValue.map { [.text($0, thinking: false)] } ?? []
        case "thinking":
            return data["text"]?.stringValue.map { [.text($0, thinking: true)] } ?? []
        case "tool-call":
            let input = parsedInput(data["input"])
            let title = input["_acp"]?["title"]?.stringValue ?? input["description"]?.stringValue
            return [.toolCall(id: callId(data), name: data["name"]?.stringValue ?? "tool", input: input, title: title)]
        case "tool-result", "tool-call-result":
            return [.toolResult(id: callId(data), content: data["output"] ?? .null, isError: data["isError"]?.boolValue ?? false, append: false)]
        case "terminal-output":
            return [.toolResult(id: callId(data), content: data["data"] ?? .null, isError: false, append: true)]
        case "file-edit":
            let id = data["id"]?.stringValue ?? UUID().uuidString
            let input: JSONValue = ["file_path": data["filePath"] ?? .null, "description": data["description"] ?? .null, "diff": data["diff"] ?? .null]
            return [.toolCall(id: id, name: "file-edit", input: input, title: data["description"]?.stringValue),
                    .toolResult(id: id, content: data["diff"] ?? .null, isError: false, append: false)]
        case "permission-request":
            let id = data["permissionId"]?.stringValue ?? ""
            return [.toolCall(id: id, name: data["toolName"]?.stringValue ?? "tool", input: data["options"] ?? .null, title: data["description"]?.stringValue)]
        case "context-compaction":
            return [.event(kind: "context-compaction", data: data)]
        default:
            return []
        }
    }

    private static func callId(_ data: JSONValue) -> String {
        data["callId"]?.stringValue ?? data["id"]?.stringValue ?? ""
    }

    private static func parsedInput(_ input: JSONValue?) -> JSONValue {
        if let string = input?.stringValue, let parsed = try? JSONValue.parse(string) { return parsed }
        return input ?? .null
    }
}
