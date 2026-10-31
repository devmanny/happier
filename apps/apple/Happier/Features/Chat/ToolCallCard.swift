import HappierKit
import SwiftUI

/// Ordinary tools fold into a muted line; questions keep their prompt and recorded answers.
struct ToolCallCard: View {
    let tool: ToolCall
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var expanded = false

    private var pending: Bool { tool.permission?.status == .pending }

    var body: some View {
        if pending {
            approvalCard
        } else if let questionnaire = tool.questionnaire {
            questionHistory(questionnaire)
        } else {
            minimalRow
        }
    }

    private func questionHistory(_ questionnaire: StructuredQuestionnaire) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: questionnaire.isAnswered ? "checkmark.circle.fill" : "questionmark.circle")
                    .foregroundStyle(questionnaire.isAnswered ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                Text(questionnaire.isAnswered ? String(localized: "Answered") : String(localized: "Not answered"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("answered-question-status-\(tool.itemId)")
            }
            ForEach(Array(questionnaire.questions.enumerated()), id: \.element.id) { index, question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.id)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("question-prompt-\(tool.itemId)-\(index)")
                    if let answers = question.answers, !answers.isEmpty {
                        ForEach(Array(answers.enumerated()), id: \.offset) { answerIndex, answer in
                            Text(answer.isEmpty ? String(localized: "Empty answer") : question.label(for: answer))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("question-answer-\(tool.itemId)-\(index)-\(answerIndex)")
                        }
                    } else {
                        Text("No answer recorded")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            }
            DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { value in
                AppHaptics.light()
                expanded = value
            })) {
                details
            } label: {
                Text("Technical details").font(.caption)
            }
            .tint(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("answered-question-\(tool.itemId)")
    }

    // MARK: Minimal row

    private var minimalRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                AppHaptics.light()
                withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    // While it runs, the Happier mark in place of the tool's icon (Core Animation:
                    // a sweep of light here redrew the whole conversation every frame).
                    if tool.state == .running {
                        HappierSpinner(size: HappierSpinner.mini)
                    } else {
                        Image(systemName: ToolPresentation.icon(for: tool))
                            .font(.caption2)
                            .frame(width: 14)
                    }
                    Text(ToolPresentation.name(for: tool))
                        .font(.caption.weight(.medium))
                    if let summary = ToolPresentation.summary(tool) {
                        Text(summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    DisclosureChevron(expanded: expanded)
                    Spacer(minLength: 4)
                    if tool.state == .error {
                        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
                    }
                }
                .foregroundStyle(.secondary)
                .accessibilityValue(tool.state == .running ? Text("Running") : Text(""))
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
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
                    AppHaptics.light()
                    withAnimation(.smooth) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: ToolPresentation.icon(for: tool))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ToolPresentation.name(for: tool))
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
                .buttonStyle(.pressable)

                if expanded { details }

                if let permission = tool.permission {
                    if permission.kind == .userAction, tool.questionnaire != nil {
                        QuestionForm(tool: tool, sessionId: sessionId)
                    } else if PermissionPrompt(agentId: nil, tool: tool.name, input: tool.input).isPlanReview {
                        PlanReview(tool: tool, sessionId: sessionId)
                    } else {
                        PermissionButtons(tool: tool, sessionId: sessionId)
                    }
                }
            }
            .padding(12)
            // Amber glass, like the older-CLI bubble: something waits on you, not an error.
            .glassEffect(.regular.tint(.orange.opacity(0.22)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 40)
        }
    }

    /// The result as it reads best (a diff, the command's output, a checklist…), with the raw
    /// input and output a tap away; just the raw ones for other tools.
    @ViewBuilder private var details: some View {
        if let rendered = ToolRendering.body(tool) {
            VStack(alignment: .leading, spacing: 6) {
                ToolBodyView(content: rendered)
                DisclosureGroup {
                    rawDetails
                } label: {
                    Text("Raw Input and Output").font(.caption)
                }
                .tint(.secondary)
            }
        } else {
            rawDetails
        }
    }

    @ViewBuilder private var rawDetails: some View {
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
                AppHaptics.light()
                withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if running {
                        HappierSpinner(size: HappierSpinner.mini)
                    } else {
                        Image(systemName: "square.stack.3d.up")
                            .font(.caption2)
                            .frame(width: 14)
                    }
                    Text("\(tools.count) tools")
                        .font(.caption.weight(.medium))
                    if !expanded, let last = tools.last {
                        Text([ToolPresentation.name(for: last), ToolPresentation.summary(last)].compactMap { $0 }.joined(separator: " "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    DisclosureChevron(expanded: expanded)
                    Spacer(minLength: 4)
                    if failed, !running {
                        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
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

/// Allow, always (this tool, a command family, every edit), deny (with feedback), or stop. The
/// options follow the agent and tool (`PermissionFooter.tsx`).
private struct PermissionButtons: View {
    let tool: ToolCall
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var busy = false
    @State private var feedback: String?

    private var prompt: PermissionPrompt {
        PermissionPrompt(agentId: store.sessions[sessionId]?.agentId, tool: tool.name, input: tool.input)
    }

    var body: some View {
        let prompt = prompt
        HStack(spacing: 8) {
            Button("Allow") { reply(.allow) }.buttonStyle(.glassProminent).glassHover()
            alwaysButton(prompt)
            Spacer(minLength: 0)
            Menu {
                Button("Deny", systemImage: "xmark", role: .destructive) { reply(.deny(reason: nil)) }
                if prompt.acceptsDenialFeedback {
                    Button("Deny with Feedback…", systemImage: "text.bubble") { feedback = "" }
                }
                Button("Deny and Stop", systemImage: "stop.circle", role: .destructive) { reply(.stop) }
            } label: {
                // Red text, not `.tint(.red)`: on the Mac a tinted glass button fills red and
                // its red label disappears.
                Text("Deny").foregroundStyle(.red)
            } primaryAction: {
                reply(.deny(reason: nil))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .glassHover()
            .fixedSize()
        }
        .controlSize(.small)
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
        .alert("What should the agent do instead?", isPresented: Binding(get: { feedback != nil }, set: { if !$0 { feedback = nil } })) {
            TextField("Feedback", text: Binding(get: { feedback ?? "" }, set: { feedback = $0 }), axis: .vertical)
            Button("Deny") { reply(.deny(reason: feedback)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent gets this with the denial and continues from it.")
        }
    }

    /// "Always": a menu when there is more than one way to stop being asked.
    @ViewBuilder
    private func alwaysButton(_ prompt: PermissionPrompt) -> some View {
        let primary: (title: LocalizedStringKey, reply: PermissionReply)? = prompt.offersAllEdits
            ? ("Allow All Edits", .allowAllEdits)
            : prompt.offersAlwaysForTool ? ("Always", .allowForSession) : nil
        let grants = prompt.commandGrants
        let execPolicy = prompt.execPolicyCommand
        if let primary {
            if grants.isEmpty, execPolicy == nil {
                Button(primary.title) { reply(primary.reply) }.buttonStyle(.glass).glassHover()
            } else {
                Menu {
                    Button(prompt.offersAllEdits ? "Allow All Edits This Session" : "Allow This Tool This Session") { reply(primary.reply) }
                    ForEach(grants) { grant in
                        switch grant.kind {
                        case .subcommand: Button("Allow “\(grant.label)” This Session") { reply(.allowCommand(grant.identifier)) }
                        case .commandName: Button("Allow Any “\(grant.label)” Command This Session") { reply(.allowCommand(grant.identifier)) }
                        }
                    }
                    if let execPolicy {
                        Button("Always Allow “\(execPolicy.joined(separator: " "))”") { reply(.allowExecPolicy(execPolicy)) }
                    }
                } label: {
                    Text(primary.title)
                } primaryAction: {
                    reply(primary.reply)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .glassHover()
                .fixedSize()
            }
        }
    }

    private func reply(_ answer: PermissionReply) {
        guard let permission = tool.permission else { return }
        busy = true
        switch answer {
        case .deny, .stop: AppHaptics.warning()
        default: AppHaptics.confirm()
        }
        Task {
            await store.reply(answer, to: (permission.id, tool.name), in: sessionId)
            busy = false
        }
    }
}

/// ExitPlanMode: the plan, then approve it (optionally switching how the agent asks from now on),
/// send it back with what to change, or reject it (`ExitPlanToolView.tsx`).
private struct PlanReview: View {
    let tool: ToolCall
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var busy = false
    @State private var changes: String?
    @State private var showsWholePlan = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let plan = PermissionPrompt(agentId: nil, tool: tool.name, input: tool.input).plan, !plan.isEmpty {
                ScrollView {
                    MarkdownText(plan)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: showsWholePlan ? nil : 260)
                .scrollBounceBehavior(.basedOnSize)
                Button(showsWholePlan ? "Show Less" : "Show Whole Plan") {
                    AppHaptics.light()
                    withAnimation(.smooth) { showsWholePlan.toggle() }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                Menu {
                    Button("Approve") { reply(.approvePlan(mode: nil)) }
                    Button("Approve and Accept Edits") { reply(.approvePlan(mode: "acceptEdits")) }
                    Button("Approve with Default Permissions") { reply(.approvePlan(mode: "default")) }
                    Button("Approve and Bypass All Permissions", role: .destructive) { reply(.approvePlan(mode: "bypassPermissions")) }
                } label: {
                    Text("Approve Plan")
                } primaryAction: {
                    reply(.approvePlan(mode: nil))
                }
                .menuStyle(.button)
                .buttonStyle(.glassProminent)
                .glassHover()
                .fixedSize()
                Button("Request Changes…") { changes = "" }.buttonStyle(.glass).glassHover()
                Spacer(minLength: 0)
                Button { reply(.rejectPlan(feedback: nil)) } label: { Text("Reject").foregroundStyle(.red) }
                    .buttonStyle(.glass)
                    .glassHover()
            }
            .controlSize(.small)
        }
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
        .alert("What should change in the plan?", isPresented: Binding(get: { changes != nil }, set: { if !$0 { changes = nil } })) {
            TextField("Changes", text: Binding(get: { changes ?? "" }, set: { changes = $0 }), axis: .vertical)
            Button("Send") {
                guard let text = changes, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                reply(.rejectPlan(feedback: text))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent revises the plan and asks again.")
        }
    }

    private func reply(_ answer: PermissionReply) {
        guard let permission = tool.permission else { return }
        busy = true
        if case .rejectPlan = answer { AppHaptics.warning() } else { AppHaptics.confirm() }
        Task {
            await store.reply(answer, to: (permission.id, tool.name), in: sessionId)
            busy = false
        }
    }
}

/// AskUserQuestion: `arguments.questions[] = {question, header, options[], multiSelect, freeform}`.
/// A question with no options (or a `freeform` one) is answered by typing
/// (`structuredQuestionAnswersV1.ts`: `allowsFreeform`).
private struct QuestionForm: View {
    let tool: ToolCall
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var selected: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]
    @State private var busy = false

    private var questions: [StructuredQuestionnaire.Question] { tool.questionnaire?.questions ?? [] }

    /// What goes back for a question: the picked options, else what was typed.
    private func answer(_ question: StructuredQuestionnaire.Question) -> [String]? {
        let picked = selected[question.id, default: []]
        if !picked.isEmpty { return question.options.filter { picked.contains($0.value) }.map(\.value) }
        let text = typed[question.id] ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [text] }
        return question.allowsEmpty ? [""] : nil
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
                        .buttonStyle(.pressable)
                    }
                    if question.typesAnswer {
                        TextField(question.placeholder ?? String(localized: "Your answer"), text: Binding(
                            get: { typed[question.id] ?? "" },
                            set: { typed[question.id] = $0 }
                        ), axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            Button("Send Answer") {
                AppHaptics.confirm()
                busy = true
                var answers: [String: [String]] = [:]
                for question in questions { answers[question.id] = answer(question) ?? [] }
                Task {
                    await store.answer(answers, to: tool.permission?.id ?? tool.id, in: sessionId)
                    busy = false
                }
            }
            .buttonStyle(.glassProminent)
            .glassHover()
            .controlSize(.small)
            .disabled(busy || questions.isEmpty || questions.contains { answer($0) == nil })
        }
    }

    private func toggle(_ question: StructuredQuestionnaire.Question, _ value: String) {
        AppHaptics.selection()
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
    /// By the tool's canonical name (`ToolRendering`), so every agent's shell reads as Terminal.
    static func icon(for tool: ToolCall) -> String {
        let name = ToolRendering.canonicalName(tool)
        return name.hasPrefix("mcp__") ? "puzzlepiece.extension" : icon(name)
    }

    static func name(for tool: ToolCall) -> String {
        ToolRendering.mcpTitle(tool.name) ?? name(ToolRendering.canonicalName(tool))
    }

    static func icon(_ name: String) -> String {
        switch name.lowercased() {
        case "patch", "diff": "pencil"
        case "delete": "trash"
        case "codesearch": "magnifyingglass"
        case "subagent": "person.2"
        case "reasoning": "brain"
        case "todoread": "checklist"
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
        case "todowrite", "todoread": String(localized: "To-dos")
        case "subagent": String(localized: "Agent")
        case "codesearch": String(localized: "Search")
        case "reasoning": String(localized: "Reasoning")
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
