import HappierKit
import SwiftUI

/// A tool's result the way it reads best: a diff for edits and patches, a terminal for commands,
/// the file for a read, a checklist for to-dos, Markdown for plans and fetched pages.
struct ToolBodyView: View {
    let content: ToolRendering.Body

    var body: some View {
        switch content {
        case .diff(let files):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in DiffFileView(file: file) }
            }
        case .shell(let command, let output, let errors, let exitCode):
            ShellOutputView(command: command, output: output, errors: errors, exitCode: exitCode)
        case .file(let path, let text, let startLine):
            FileExcerptView(path: path, text: text, startLine: startLine)
        case .list(let items):
            ListOutputView(items: items)
        case .todos(let todos):
            TodoChecklistView(todos: todos)
        case .markdown(let text):
            ToolPanel {
                MarkdownText(text)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .text(let text):
            ToolPanel { MonospaceText(text: text) }
        }
    }
}

/// The rounded, scrolling background every tool body sits on.
private struct ToolPanel<Content: View>: View {
    var maxHeight: CGFloat = 320
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView([.vertical, .horizontal]) { content }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MonospaceText: View {
    let text: String
    var color: Color = .primary

    var body: some View {
        Text(text.count > 20_000 ? "…" + String(text.suffix(20_000)) : text)
            .font(.caption.monospaced())
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }
}

// MARK: Diffs

private struct DiffFileView: View {
    let file: TextDiff.File
    private static let lineLimit = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: file.isDeletion ? "trash" : "doc.text").font(.caption2)
                Text(file.path.map { ($0 as NSString).lastPathComponent } ?? String(localized: "Changes"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path ?? "")
                if file.isDeletion { Text("Deleted").font(.caption2).foregroundStyle(.red) }
                Spacer(minLength: 4)
                if file.diff.added > 0 { Text("+\(file.diff.added)").foregroundStyle(.green) }
                if file.diff.removed > 0 { Text("−\(file.diff.removed)").foregroundStyle(.red) }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            ToolPanel {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.diff.lines.prefix(Self.lineLimit)) { line in DiffLineView(line: line) }
                    if file.diff.lines.count > Self.lineLimit {
                        Text("\(file.diff.lines.count - Self.lineLimit) more lines")
                            .font(.caption2).foregroundStyle(.secondary).padding(6)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct DiffLineView: View {
    let line: TextDiff.Line

    var body: some View {
        switch line.kind {
        case .gap:
            Text("⋯").font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.vertical, 2)
        case .hunk:
            Text(line.text.isEmpty ? "@@" : line.text)
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08))
        default:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 26, alignment: .trailing)
                Text(marker).font(.caption.monospaced()).foregroundStyle(markerColor)
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.caption.monospaced())
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibility))
        }
    }

    private var number: String { (line.newNumber ?? line.oldNumber).map(String.init) ?? "" }
    private var marker: String { line.kind == .added ? "+" : line.kind == .removed ? "−" : " " }
    private var markerColor: Color { line.kind == .added ? .green : line.kind == .removed ? .red : .secondary }
    private var background: Color {
        switch line.kind {
        case .added: .green.opacity(0.12)
        case .removed: .red.opacity(0.12)
        default: .clear
        }
    }
    private var accessibility: String {
        switch line.kind {
        case .added: String(localized: "Added: \(line.text)")
        case .removed: String(localized: "Removed: \(line.text)")
        default: line.text
        }
    }
}

// MARK: Commands

private struct ShellOutputView: View {
    let command: String?
    let output: String?
    let errors: String?
    let exitCode: Int?

    var body: some View {
        ToolPanel {
            VStack(alignment: .leading, spacing: 0) {
                if let command {
                    Text("$ \(command)")
                        .font(.caption.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                        .padding([.horizontal, .top], 8)
                }
                if let output, !output.isEmpty { MonospaceText(text: output) }
                if let errors { MonospaceText(text: errors, color: .orange) }
                if let exitCode, exitCode != 0 {
                    Label("Exited with code \(exitCode)", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding([.horizontal, .bottom], 8)
                }
                if command != nil, (output ?? "").isEmpty, errors == nil, exitCode == nil {
                    Text("No output").font(.caption2).foregroundStyle(.tertiary).padding(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Files and lists

private struct FileExcerptView: View {
    let path: String?
    let text: String
    let startLine: Int
    private static let lineLimit = 400

    var body: some View {
        let lines = TextLines.split(text)
        ToolPanel {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(Self.lineLimit).enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(startLine + index))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(minWidth: 26, alignment: .trailing)
                        Text(line.isEmpty ? " " : line).font(.caption.monospaced()).fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 6)
                }
                if lines.count > Self.lineLimit {
                    Text("\(lines.count - Self.lineLimit) more lines").font(.caption2).foregroundStyle(.secondary).padding(6)
                }
            }
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
    }
}

private struct ListOutputView: View {
    let items: [String]
    private static let limit = 60

    var body: some View {
        ToolPanel(maxHeight: 260) {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.prefix(Self.limit).enumerated()), id: \.offset) { _, item in
                    Text(item).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                if items.count > Self.limit {
                    Text("and \(items.count - Self.limit) more").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}

private struct TodoChecklistView: View {
    let todos: [ToolRendering.Todo]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(todos) { todo in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(todo.status))
                        .foregroundStyle(color(todo.status))
                        .font(.caption)
                    Text(todo.text)
                        .font(.subheadline)
                        .strikethrough(todo.status == .completed || todo.status == .cancelled)
                        .foregroundStyle(todo.status == .completed || todo.status == .cancelled ? .secondary : .primary)
                        .fontWeight(todo.status == .inProgress ? .semibold : .regular)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(label(todo.status)))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func icon(_ status: ToolRendering.Todo.Status) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private func color(_ status: ToolRendering.Todo.Status) -> Color {
        switch status {
        case .completed: .green
        case .inProgress: .accentColor
        default: .secondary
        }
    }

    private func label(_ status: ToolRendering.Todo.Status) -> String {
        switch status {
        case .pending: String(localized: "Pending")
        case .inProgress: String(localized: "In progress")
        case .completed: String(localized: "Done")
        case .cancelled: String(localized: "Cancelled")
        }
    }
}

/// Lines of a text as the diff splits them (no empty last line for a final newline).
private enum TextLines {
    static func split(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}
