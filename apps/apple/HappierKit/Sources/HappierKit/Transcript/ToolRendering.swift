import Foundation

/// What a tool card shows, across providers (`normalizeToolCallForRendering` and the
/// `renderers/fileOps|system|workflow|web` views). Codex and ACP calls arrive with the CLI's
/// canonical name (`_happier.canonicalToolName`); Claude's arrive raw and are named here.
public enum ToolRendering {
    public enum Body: Sendable, Equatable {
        /// Edits, writes, patches and turn diffs, one entry per file.
        case diff([TextDiff.File])
        case shell(command: String?, output: String?, errors: String?, exitCode: Int?)
        /// A file read, from `startLine`.
        case file(path: String?, text: String, startLine: Int)
        /// Matched files or lines (Glob, Grep, LS).
        case list([String])
        case todos([Todo])
        case markdown(String)
        case text(String)
    }

    public struct Todo: Sendable, Equatable, Identifiable {
        public enum Status: Sendable, Equatable { case pending, inProgress, completed, cancelled }
        public let id: Int
        public let text: String
        public let status: Status
    }

    // MARK: Names

    public static func canonicalName(_ tool: ToolCall) -> String {
        let input = tool.input
        for key in ["_happier", "_happy"] {
            if let name = input[key]?["canonicalToolName"]?.stringValue, !name.isEmpty { return name }
        }
        let raw = tool.name
        if raw.hasPrefix("mcp__") { return raw }
        func has(_ keys: String...) -> Bool { keys.contains { input[$0] != nil && input[$0]?.isNull == false } }
        let hasChanges = (input["changes"]?.objectValue?.isEmpty == false) || (input["changes"]?.arrayValue?.isEmpty == false)
        switch raw.lowercased() {
        case "bash", "codexbash", "geminibash", "execute", "exec_command", "execute_command", "shell", "shell_command": return "Bash"
        case "patch", "codexpatch", "geminipatch", "apply_patch", "apply_diff": return "Patch"
        case "diff", "codexdiff", "geminidiff": return "Diff"
        case "edit", "edit_file":
            if hasChanges { return "Patch" }
            if input["edits"]?.arrayValue != nil { return "MultiEdit" }
            if has("content", "file_content", "text"), !has("old_string", "new_string", "oldText", "newText", "oldString", "newString") { return "Write" }
            return "Edit"
        case "multiedit": return "MultiEdit"
        case "write", "write_file", "write_to_file": return input["todos"]?.arrayValue != nil ? "TodoWrite" : "Write"
        case "read", "read_file", "readfile": return "Read"
        case "delete", "remove": return hasChanges ? "Patch" : "Delete"
        case "glob", "find": return "Glob"
        case "grep": return "Grep"
        case "ls", "list_files", "ls_files": return "LS"
        case "search", "search_code", "code_search": return "CodeSearch"
        case "fetch": return has("url", "href", "uri", "link") ? "WebFetch" : has("query", "q") ? "WebSearch" : raw
        case "webfetch", "web_fetch": return "WebFetch"
        case "websearch", "web_search": return "WebSearch"
        case "think", "codexreasoning", "geminireasoning": return "Reasoning"
        case "task", "agent", "subagent", "taskcreate", "tasklist", "taskupdate": return "SubAgent"
        case "taskoutput", "task_output": return "TaskOutput"
        case "taskstop", "task_stop": return "TaskStop"
        case "todowrite": return "TodoWrite"
        case "todoread": return "TodoRead"
        case "exitplanmode", "exit_plan_mode": return "ExitPlanMode"
        case "enterplanmode": return "EnterPlanMode"
        case "askuserquestion", "ask_user_question": return "AskUserQuestion"
        case "file-edit": return has("diff") ? "Diff" : "Edit"
        default: return raw
        }
    }

    /// `mcp__linear__create_issue` → "Linear: Create Issue" (`formatMCPTitle`).
    public static func mcpTitle(_ name: String) -> String? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.dropFirst(5).components(separatedBy: "__").filter { !$0.isEmpty }
        guard let server = parts.first else { return nil }
        func words(_ text: String) -> String {
            text.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        let action = parts.dropFirst().joined(separator: " ")
        return action.isEmpty ? words(server) : "\(words(server)): \(words(action))"
    }

    // MARK: Bodies

    /// The view for this tool, or nil for the raw input and output.
    public static func body(_ tool: ToolCall) -> Body? {
        let input = tool.input
        let result = tool.structuredResult ?? tool.result
        let name = canonicalName(tool)
        switch name {
        case "Edit":
            guard let old = string(input, "old_string", "oldText", "oldString"), let new = string(input, "new_string", "newText", "newString") else {
                return unifiedFromFileEdit(tool)
            }
            return .diff([TextDiff.File(path: path(input), diff: TextDiff(old: old, new: new))])
        case "MultiEdit":
            let edits = (input["edits"]?.arrayValue ?? []).compactMap { edit -> TextDiff.File? in
                guard let old = string(edit, "old_string", "oldText"), let new = string(edit, "new_string", "newText") else { return nil }
                return TextDiff.File(path: path(input), diff: TextDiff(old: old, new: new))
            }
            return edits.isEmpty ? nil : .diff(edits)
        case "Write":
            guard let content = string(input, "content", "file_content", "text") else { return nil }
            return .diff([TextDiff.File(path: path(input), diff: TextDiff(old: "", new: content))])
        case "Patch":
            let files = patchFiles(input)
            return files.isEmpty ? nil : .diff(files)
        case "Diff":
            return diffFiles(input).map(Body.diff) ?? unifiedFromFileEdit(tool)
        case "Bash":
            return shell(command: PermissionPrompt.shellCommand(input), result: result)
        case "Read":
            guard tool.state == .completed, let text = string(result?["file"], "content") ?? string(result, "content") ?? result?.stringValue else { return nil }
            return .file(path: path(input), text: text, startLine: result?["file"]?["startLine"]?.intValue ?? 1)
        case "Glob", "LS", "Grep", "CodeSearch":
            let items = listItems(result)
            return items.isEmpty ? nil : .list(items)
        case "TodoWrite", "TodoRead":
            let todos = todoItems(result?["newTodos"]?.arrayValue ?? result?["todos"]?.arrayValue ?? input["todos"]?.arrayValue ?? [])
            return todos.isEmpty ? nil : .todos(todos)
        case "ExitPlanMode":
            return string(input, "plan").map(Body.markdown)
        case "WebFetch":
            return string(result, "result", "text", "content", "body", "markdown", "output").map(Body.markdown)
        default:
            if name.hasPrefix("mcp__") {
                let text = string(result, "text", "message", "result", "output") ?? result.map(\.flattenedText)
                return text.flatMap { $0.isEmpty ? nil : .text($0) }
            }
            return nil
        }
    }

    // MARK: Helpers

    private static func string(_ value: JSONValue?, _ keys: String...) -> String? {
        for key in keys { if let text = value?[key]?.stringValue { return text } }
        return nil
    }

    private static func path(_ input: JSONValue) -> String? {
        string(input, "file_path", "path", "filePath") ?? input["locations"]?[0]?["path"]?.stringValue
    }

    /// The pre-normalization `file-edit` record (`{file_path, diff}`) or any input with a unified diff.
    private static func unifiedFromFileEdit(_ tool: ToolCall) -> Body? {
        guard let text = string(tool.input, "diff", "unified_diff") ?? (tool.name == "file-edit" ? tool.result?.stringValue : nil) else { return nil }
        let files = TextDiff.files(fromUnified: text).map { file in
            TextDiff.File(path: file.path ?? path(tool.input), diff: file.diff, isDeletion: file.isDeletion)
        }
        return files.isEmpty ? nil : .diff(files)
    }

    private static func diffFiles(_ input: JSONValue) -> [TextDiff.File]? {
        if let entries = input["files"]?.arrayValue, !entries.isEmpty {
            let files = entries.flatMap { entry -> [TextDiff.File] in
                let path = string(entry, "file_path", "path", "filePath")
                if let unified = string(entry, "unified_diff", "diff") {
                    return TextDiff.files(fromUnified: unified).map { TextDiff.File(path: path ?? $0.path, diff: $0.diff, isDeletion: $0.isDeletion) }
                }
                if let old = string(entry, "oldText", "old_text"), let new = string(entry, "newText", "new_text") {
                    return [TextDiff.File(path: path, diff: TextDiff(old: old, new: new))]
                }
                return []
            }
            return files.isEmpty ? nil : files
        }
        guard let text = string(input, "unified_diff", "diff", "patch") else { return nil }
        let files = TextDiff.files(fromUnified: text)
        return files.isEmpty ? nil : files
    }

    /// `changes` as a map or an array (Codex app-server), or patch text (`apply_patch` or unified).
    private static func patchFiles(_ input: JSONValue) -> [TextDiff.File] {
        if let map = input["changes"]?.objectValue {
            return map.keys.sorted().compactMap { patchFile(path: $0, change: map[$0]!) }
        }
        if let list = input["changes"]?.arrayValue {
            return list.compactMap { entry in
                guard let path = string(entry, "path") else { return nil }
                return patchFile(path: entry["kind"]?["move_path"]?.stringValue ?? path, change: [
                    "type": entry["kind"]?["type"] ?? .null, "unified_diff": entry["diff"] ?? .null,
                ])
            }
        }
        guard let text = string(input, "patch", "patchText", "patch_text", "unified_diff", "diff") else { return [] }
        return text.contains("*** Begin Patch") || text.contains("*** Update File:") || text.contains("*** Add File:")
            ? TextDiff.files(fromApplyPatch: text)
            : TextDiff.files(fromUnified: text)
    }

    private static func patchFile(path: String, change: JSONValue) -> TextDiff.File? {
        if let added = change["add"] { return TextDiff.File(path: path, diff: TextDiff(old: "", new: string(added, "content") ?? "")) }
        if let removed = change["delete"] { return TextDiff.File(path: path, diff: TextDiff(old: string(removed, "content") ?? "", new: ""), isDeletion: true) }
        if let modified = change["modify"] {
            return TextDiff.File(path: path, diff: TextDiff(old: string(modified, "old_content") ?? "", new: string(modified, "new_content") ?? ""))
        }
        let type = change["type"]?.stringValue
        if let unified = string(change, "unified_diff"), let file = TextDiff.files(fromUnified: unified).first {
            return TextDiff.File(path: path, diff: file.diff, isDeletion: type == "delete")
        }
        if let old = string(change, "old_content"), let new = string(change, "new_content") {
            return TextDiff.File(path: path, diff: TextDiff(old: old, new: new))
        }
        let content = string(change, "content") ?? ""
        switch type {
        case "add": return TextDiff.File(path: path, diff: TextDiff(old: "", new: content))
        case "delete": return TextDiff.File(path: path, diff: TextDiff(old: content, new: ""), isDeletion: true)
        default: return nil
        }
    }

    private static func shell(command: String?, result: JSONValue?) -> Body {
        guard let result, !result.isNull else { return .shell(command: command, output: nil, errors: nil, exitCode: nil) }
        if result.objectValue != nil {
            let output = string(result, "stdout", "aggregated_output", "formatted_output", "output")
                ?? result["content"]?.arrayValue.map { JSONValue.array($0).flattenedText }
            let errors = string(result, "stderr", "error").flatMap { $0.isEmpty ? nil : $0 }
            return .shell(command: command, output: output, errors: errors, exitCode: result["exit_code"]?.intValue ?? result["exitCode"]?.intValue)
        }
        return .shell(command: command, output: result.flattenedText, errors: nil, exitCode: nil)
    }

    /// Claude's `{filenames, content}`, the CLI's `matches`/`entries`/`files`, or plain text lines.
    private static func listItems(_ result: JSONValue?) -> [String] {
        guard let result else { return [] }
        if let content = result["content"]?.stringValue, !content.isEmpty { return TextDiff.split(content) }
        for key in ["filenames", "matches", "entries", "files"] {
            guard let items = result[key]?.arrayValue else { continue }
            return items.compactMap { item in
                if let text = item.stringValue { return text }
                guard let file = string(item, "filePath", "file_path", "path", "file") else { return nil }
                let line = (item["line"] ?? item["line_number"])?.intValue
                let excerpt = string(item, "excerpt", "text", "snippet")
                return [line.map { "\(file):\($0)" } ?? file, excerpt].compactMap { $0 }.joined(separator: "  ")
            }
        }
        if let items = result.arrayValue { return items.compactMap(\.stringValue) }
        if let text = result.stringValue ?? string(result, "stdout") { return TextDiff.split(text) }
        return []
    }

    private static func todoItems(_ items: [JSONValue]) -> [Todo] {
        items.enumerated().compactMap { index, item in
            guard let text = string(item, "content", "title", "text") else { return nil }
            let status: Todo.Status = switch item["status"]?.stringValue {
            case "in_progress", "doing", "active": .inProgress
            case "completed", "done": .completed
            case "cancelled", "canceled": .cancelled
            default: .pending
            }
            return Todo(id: index, text: text, status: status)
        }
    }
}
