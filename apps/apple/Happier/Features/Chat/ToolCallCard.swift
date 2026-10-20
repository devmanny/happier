import HappierKit
import SwiftUI

/// Tool call: a single muted line (tap to expand); a full card only when it needs approval.
struct ToolCallCard: View {
    let tool: ToolCall
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var expanded = false

    private var pending: Bool { tool.permission?.status == .pending }

    var body: some View {
        if pending { approvalCard } else { minimalRow }
    }

    // MARK: Minimal row

    private var minimalRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: ToolPresentation.icon(tool.name))
                        .font(.caption2)
                        .frame(width: 14)
                    Text(ToolPresentation.name(tool.name))
                        .font(.caption.weight(.medium))
                    if let summary = ToolPresentation.summary(tool) {
                        Text(summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    switch tool.state {
                    case .running: HappierSpinner(size: HappierSpinner.mini)
                    case .error: Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
                    case .completed: EmptyView()
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides details" : "Shows details")

            if expanded {
                details
                    .padding(.leading, 24)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.trailing, 40)
    }

    // MARK: Approval card

    private var approvalCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.smooth) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: ToolPresentation.icon(tool.name))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ToolPresentation.name(tool.name))
                                .font(.subheadline.weight(.semibold))
                            if let summary = ToolPresentation.summary(tool) {
                                Text(summary)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(expanded ? 4 : 2)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded { details }

                if let permission = tool.permission {
                    if permission.kind == .userAction, tool.name.lowercased().contains("question") {
                        QuestionForm(tool: tool, sessionId: sessionId)
                    } else {
                        PermissionButtons(tool: tool, sessionId: sessionId)
                    }
                }
            }
            .padding(12)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.6), lineWidth: 1.5)
            }
            Spacer(minLength: 40)
        }
    }

    @ViewBuilder private var details: some View {
        if !tool.input.isNull, let input = ToolPresentation.pretty(tool.input) {
            CodeBlock(title: "Input", text: input)
        }
        if let result = tool.result {
            CodeBlock(title: tool.state == .error ? "Error" : "Output", text: result.flattenedText)
        }
    }
}

/// Consecutive tool calls collapsed into one line ("5 tools"); tap to list them.
struct ToolGroupRow: View {
    let tools: [ToolCall]
    let sessionId: String
    @State private var expanded = false

    private var running: Bool { tools.contains { $0.state == .running } }
    private var failed: Bool { tools.contains { $0.state == .error } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.caption2)
                        .frame(width: 14)
                    Text("\(tools.count) tools")
                        .font(.caption.weight(.medium))
                    if !expanded, let last = tools.last {
                        Text([ToolPresentation.name(last.name), ToolPresentation.summary(last)].compactMap { $0 }.joined(separator: " "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 4)
                    if running {
                        HappierSpinner(size: HappierSpinner.mini)
                    } else if failed {
                        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tools.count) tool calls")
            .accessibilityHint(expanded ? "Hides the list" : "Shows each tool")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tools, id: \.itemId) { tool in
                        ToolCallCard(tool: tool, sessionId: sessionId)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.quaternary).frame(width: 1).padding(.leading, 10)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.trailing, 40)
    }
}

private struct CodeBlock: View {
    let title: LocalizedStringKey
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            ScrollView([.vertical, .horizontal]) {
                Text(text.count > 20_000 ? String(text.prefix(20_000)) + "\n…" : text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct PermissionButtons: View {
    let tool: ToolCall
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var busy = false

    var body: some View {
        HStack(spacing: 8) {
            button("Allow", .allow, prominent: true)
            button("Always", .allowForSession)
            Spacer(minLength: 0)
            Menu {
                Button("Deny", systemImage: "xmark", role: .destructive) { reply(.deny(reason: nil)) }
                Button("Deny and Stop", systemImage: "stop.circle", role: .destructive) { reply(.stop) }
            } label: {
                Text("Deny")
            } primaryAction: {
                reply(.deny(reason: nil))
            }
            .fixedSize()
            .tint(.red)
        }
        .controlSize(.small)
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
    }

    @ViewBuilder
    private func button(_ title: LocalizedStringKey, _ answer: PermissionReply, prominent: Bool = false) -> some View {
        if prominent {
            Button(title) { reply(answer) }.buttonStyle(.borderedProminent)
        } else {
            Button(title) { reply(answer) }.buttonStyle(.bordered)
        }
    }

    private func reply(_ answer: PermissionReply) {
        guard let permission = tool.permission else { return }
        busy = true
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        Task {
            await store.reply(answer, to: (permission.id, tool.name), in: sessionId)
            busy = false
        }
    }
}

/// AskUserQuestion: `arguments.questions[] = {question, header, options[], multiSelect}`.
private struct QuestionForm: View {
    let tool: ToolCall
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var selected: [String: Set<String>] = [:]
    @State private var busy = false

    private struct Question: Identifiable {
        let id: String
        let header: String?
        let multi: Bool
        let options: [(label: String, value: String, description: String?)]
    }

    private var questions: [Question] {
        (tool.input["questions"]?.arrayValue ?? []).map { q in
            let key = q["question"]?.stringValue ?? q["header"]?.stringValue ?? ""
            let options = (q["options"]?.arrayValue ?? []).map { option -> (String, String, String?) in
                if let s = option.stringValue { return (s, s, nil) }
                let label = option["label"]?.stringValue ?? ""
                let value = option["value"]?.stringValue ?? option["choice"]?.stringValue ?? label
                return (label, value, option["description"]?.stringValue)
            }
            return Question(id: key, header: q["header"]?.stringValue, multi: q["multiSelect"]?.boolValue ?? q["multiple"]?.boolValue ?? false, options: options)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.id).font(.subheadline.weight(.semibold))
                    ForEach(question.options, id: \.value) { option in
                        let isOn = selected[question.id, default: []].contains(option.value)
                        Button {
                            toggle(question, option.value)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: isOn ? (question.multi ? "checkmark.square.fill" : "largecircle.fill.circle") : (question.multi ? "square" : "circle"))
                                    .foregroundStyle(isOn ? Color.userBubble : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.subheadline)
                                    if let d = option.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button("Send Answer") {
                busy = true
                let answers = selected.mapValues { Array($0) }
                Task {
                    await store.answer(answers, to: tool.permission?.id ?? tool.id, in: sessionId)
                    busy = false
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(busy || questions.contains { selected[$0.id, default: []].isEmpty })
        }
    }

    private func toggle(_ question: Question, _ value: String) {
        var set = selected[question.id, default: []]
        if question.multi {
            if set.contains(value) { set.remove(value) } else { set.insert(value) }
        } else {
            set = [value]
        }
        selected[question.id] = set
    }
}

enum ToolPresentation {
    static func icon(_ name: String) -> String {
        switch name.lowercased() {
        case "bash", "shell", "exec", "terminal", "execute": "terminal"
        case "read", "view", "notebookread": "doc.text"
        case "edit", "multiedit", "write", "file-edit", "notebookedit", "apply_patch": "pencil"
        case "grep", "glob", "search", "ls", "find": "magnifyingglass"
        case "webfetch", "websearch", "fetch": "globe"
        case "task", "agent": "person.2"
        case "todowrite", "todo": "checklist"
        case "askuserquestion", "ask_user_question": "questionmark.bubble"
        case "exitplanmode", "exit_plan_mode": "list.bullet.clipboard"
        default: "wrench.and.screwdriver"
        }
    }

    static func name(_ name: String) -> String {
        switch name.lowercased() {
        case "bash": "Terminal"
        case "file-edit": "Edit"
        case "askuserquestion", "ask_user_question": String(localized: "Question")
        case "exitplanmode", "exit_plan_mode": String(localized: "Plan")
        case "todowrite": String(localized: "To-dos")
        default: name
        }
    }

    static func summary(_ tool: ToolCall) -> String? {
        let input = tool.input
        if let command = input["command"]?.stringValue ?? input["command"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ") {
            return command
        }
        if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? input["filePath"]?.stringValue {
            return path
        }
        if let pattern = input["pattern"]?.stringValue { return pattern }
        if let url = input["url"]?.stringValue ?? input["query"]?.stringValue { return url }
        if let title = tool.title { return title }
        if let question = input["questions"]?[0]?["question"]?.stringValue { return question }
        return nil
    }

    static func pretty(_ value: JSONValue) -> String? {
        if let string = value.stringValue { return string }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
}
