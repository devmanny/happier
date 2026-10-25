import Foundation

/// `@file` references in a message, written the way the official composer writes them
/// (`composerSuggestionGrammar.ts`, `SessionView.handleAppendLinkedPath`), so agents read them the same.
public enum FileMention {
    /// Characters that end a bare token; a path holding one is quoted.
    static let boundaries: Set<Character> = [" ", "\t", "\n", "\r", "\u{00A0}",
                                                     ",", ";", "(", ")", "[", "]", "{", "}", "<", ">", "!", "?", "\""]

    /// `@path`, or `@"path"` (inner quotes doubled) when the path has a space or delimiter.
    public static func token(_ path: String) -> String {
        guard path.isEmpty || path.contains(where: boundaries.contains) else { return "@" + path }
        return "@\"" + path.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The draft with the mention added at its end, one space apart, and a space after it.
    public static func appending(_ path: String, to draft: String) -> String {
        let spacer = draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " "
        return draft + spacer + token(path) + " "
    }

    /// The file's name as a mention pill shows it: long names keep their start and their
    /// extension around an ellipsis, so the pill stays on one line.
    public static func displayName(_ path: String, limit: Int = 28) -> String {
        let isFolder = path.hasSuffix("/")
        let trimmed = isFolder ? String(path.dropLast()) : path
        var name = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        if isFolder { name += "/" }
        guard name.count > limit, limit > 4 else { return name }
        var ext = ""
        if !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex, name.distance(from: dot, to: name.endIndex) <= 10 {
            ext = String(name[dot...])
        }
        let stem = String(name.dropLast(ext.count))
        let budget = limit - 1 - ext.count
        let head = Int((Double(budget) * 0.6).rounded(.up))
        return String(stem.prefix(head)) + "…" + String(stem.suffix(budget - head)) + ext
    }

    /// The relative paths printed by `rg --files`.
    public static func files(fromRipgrep stdout: String) -> [String] {
        stdout.split(whereSeparator: \.isNewline).compactMap { line in
            var path = line.trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("./") { path.removeFirst(2) }
            return path.isEmpty ? nil : path
        }
    }

    /// The `@` index of a folder: the files `rg --files` printed, then the folders above them
    /// (ending in `/`), each once (`buildFileItemsFromPaths` in `suggestionFile.ts`).
    public static func index(fromRipgrep stdout: String) -> [String] {
        let files = files(fromRipgrep: stdout)
        var seen = Set<String>()
        var folders: [String] = []
        for file in files {
            var parts = file.split(separator: "/", omittingEmptySubsequences: false).dropLast()
            var chain: [String] = []
            while !parts.isEmpty {
                chain.append(parts.joined(separator: "/") + "/")
                parts = parts.dropLast()
            }
            for folder in chain.reversed() where seen.insert(folder).inserted { folders.append(folder) }
        }
        return files + folders
    }

    /// Entries matching the query, best first (`fileSearchRelevance` in `suggestionFile.ts`): the
    /// exact name, then the name without its extension, then names starting with it, then
    /// names and paths holding every word, then names holding its letters in order.
    public static func search(_ entries: [String], query: String, limit: Int = 50) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "\\", with: "/")
        guard !needle.isEmpty else { return Array(entries.prefix(limit)) }
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        let letters = needle.filter { !$0.isWhitespace }
        let bare = needle.hasSuffix("/") ? String(needle.dropLast()) : needle
        let ranked = entries.compactMap { entry -> (tier: Int, entry: String)? in
            let path = entry.lowercased()
            let trimmedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
            let name = trimmedPath.split(separator: "/").last.map(String.init) ?? trimmedPath
            let tier: Int
            if trimmedPath == bare || name == bare {
                tier = 0
            } else if !needle.contains("/"), !needle.contains("."), !path.hasSuffix("/"),
                      let dot = name.lastIndex(of: "."), dot != name.startIndex, name[..<dot] == needle {
                tier = 1
            } else if !needle.contains("/"), name.hasPrefix(needle + ".") {
                tier = 2
            } else if (needle.contains("/") ? path : name).hasPrefix(needle) {
                tier = 3
            } else if words.allSatisfy(name.contains) {
                tier = 4
            } else if words.allSatisfy(path.contains) {
                tier = 5
            } else if letters.count > 1, inOrder(letters, in: name) {
                tier = 6
            } else {
                return nil
            }
            return (tier, entry)
        }
        return ranked
            .sorted { ($0.tier, $0.entry.count, $0.entry) < ($1.tier, $1.entry.count, $1.entry) }
            .prefix(limit)
            .map(\.entry)
    }

    /// `rg --iglob` pattern for names holding what was typed: glob syntax escaped, spaces as `*`
    /// (`buildFileItemsFromRipgrepGlob` in `suggestionFile.ts`).
    public static func nameGlob(_ query: String) -> String {
        var escaped = ""
        for character in query.trimmingCharacters(in: .whitespacesAndNewlines) {
            if "\\*?[]".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        let needle = escaped.split(whereSeparator: \.isWhitespace).joined(separator: "*")
        return "*\(needle)*"
    }

    private static func inOrder(_ letters: String, in name: String) -> Bool {
        var remaining = letters[...]
        for character in name where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
