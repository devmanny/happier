import HappierKit
import PhotosUI
import SwiftUI

/// Claude/ChatGPT-style composer with Happier's session controls: context chips (permission,
/// machine · folder, mode), a card with ⊕ options, the model pill, dictation and send/stop.
struct Composer: View {
    let sessionId: String
    @Binding var text: String
    let working: Bool
    let onSend: ([AttachmentDraft]) -> Void
    let onStop: () -> Void

    @Environment(HappierStore.self) private var store
    @State private var sheet: SheetKind?
    @State private var dictation = Dictation()
    @State private var attachments: [AttachmentDraft] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @FocusState private var focused: Bool

    enum SheetKind: Identifiable {
        case model
        var id: Self { self }
    }

    private var session: Session? { store.sessions[sessionId] }
    private var controls: SessionControls? { store.controls(for: sessionId) }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    /// Adds picked files, rejecting ones over the upload limit up front.
    private func add(_ drafts: [AttachmentDraft]) {
        let tooLarge = drafts.filter { $0.data.count > HappierStore.maxAttachmentBytes }
        if !tooLarge.isEmpty {
            store.lastError = String(localized: "\(tooLarge.map(\.name).joined(separator: ", ")) is larger than 25 MB.")
        }
        let accepted = drafts.filter { $0.data.count <= HappierStore.maxAttachmentBytes }
        withAnimation(.smooth) { attachments += accepted }
    }

    private func send() {
        guard canSend else { return }
        let picked = attachments
        attachments = []
        onSend(picked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let suggestions = slashSuggestions, !suggestions.isEmpty {
                SlashSuggestions(commands: suggestions) { insert($0) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            card
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.2), value: slashSuggestions?.count)
        .sheet(item: $sheet) { kind in
            ModelSheet(sessionId: sessionId)
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(32)
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                add(await AttachmentLoader.drafts(from: items))
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            add(((try? result.get()) ?? []).compactMap(AttachmentLoader.file(at:)))
        }
        .onChange(of: dictation.error) { _, error in
            if let error { store.lastError = error }
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments)
            }
            TextField(working ? "Steer or queue a message…" : "Describe a task or ask a question…", text: $text, axis: .vertical)
                .lineLimit(1...10)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focused)
                .padding(.horizontal, 6)
                .submitLabel(.send)
                .onKeyPress(.return, phases: .down) { press in
                    // Hardware keyboards: Return sends, Shift+Return inserts a newline.
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
                .onChange(of: text) { old, new in
                    // On-screen keyboard: Return arrives as a single typed "\n"; treat it as send.
                    guard new.count == old.count + 1, new.hasSuffix("\n"), !old.hasSuffix("\n") else { return }
                    text = String(new.dropLast())
                    send()
                }

            HStack(spacing: 8) {
                Menu {
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        if let draft = AttachmentLoader.clipboardImage() {
                            add([draft])
                        } else if let pasted = AttachmentLoader.clipboardText(), !pasted.isEmpty {
                            text += pasted
                            focused = true
                        }
                    }
                    Button("Photo or Video", systemImage: "photo.on.rectangle") { showPhotos = true }
                    Button("File", systemImage: "doc") { showFiles = true }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.body.weight(.medium))
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Attach")
                if let controls {
                    modelPill(controls)
                    permissionPill(controls)
                }
                Spacer(minLength: 0)
                if !canSend || dictation.isRecording {
                    CircleButton(systemImage: dictation.isRecording ? "waveform" : "mic", active: dictation.isRecording) {
                        dictation.toggle(prefix: text) { text = $0 }
                    }
                    .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                    .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                }
                sendButton
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func modelPill(_ controls: SessionControls) -> some View {
        Button {
            sheet = .model
        } label: {
            HStack(spacing: 5) {
                Text(controls.displayModelName).lineLimit(1)
                if let effort = controls.displayEffort {
                    Text(ModelSheet.effortName(effort)).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Model")
    }

    private func permissionPill(_ controls: SessionControls) -> some View {
        Menu {
            PermissionPicker(sessionId: sessionId, controls: controls)
        } label: {
            Text(controls.permissionMode.label(agentId: controls.agentId))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .accessibilityLabel("Permission mode")
    }

    @ViewBuilder private var sendButton: some View {
        let stop = working && !canSend
        Button {
            if dictation.isRecording { dictation.stop() }
            stop ? onStop() : send()
        } label: {
            Image(systemName: stop ? "stop.fill" : "arrow.up")
                .font(.body.weight(.bold))
                .frame(width: 22, height: 22)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .tint(stop ? .red : .userBubble)
        .disabled(!stop && !canSend)
        .sensoryFeedback(.impact(weight: .light), trigger: text.isEmpty)
        .accessibilityLabel(stop ? "Stop agent" : "Send")
    }

    // MARK: Slash commands (`composerSuggestionGrammar.ts`: token at start or after whitespace)

    private var slashSuggestions: [SlashCommand]? {
        guard let token = text.split(separator: " ", omittingEmptySubsequences: false).last,
              token.hasPrefix("/"), !token.contains("\n"),
              let commands = controls?.slashCommands
        else { return nil }
        let query = token.dropFirst().lowercased()
        return Array(commands.filter { query.isEmpty || $0.command.lowercased().contains(query) }.prefix(8))
    }

    private func insert(_ command: SlashCommand) {
        var parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        parts[parts.count - 1] = "/\(command.command)"
        text = parts.joined(separator: " ") + " "
    }
}

// MARK: - Pieces

private struct CircleButton: View {
    let systemImage: String
    var active = false
    let action: () -> Void

    var body: some View {
        if active {
            Button(action: action) { icon }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.userBubble)
        } else {
            Button(action: action) { icon }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        }
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.medium))
            .frame(width: 22, height: 22)
    }
}

private struct SlashSuggestions: View {
    let commands: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commands) { command in
                Button {
                    onSelect(command)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("/\(command.command)").font(.callout.monospaced().weight(.medium))
                        if let description = command.description {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct PermissionPicker: View {
    let sessionId: String
    let controls: SessionControls
    @Environment(HappierStore.self) private var store

    var body: some View {
        Picker("Permissions", selection: Binding(
            get: { controls.permissionMode },
            set: { mode in Task { await store.setPermissionMode(mode, in: sessionId) } })
        ) {
            ForEach(PermissionMode.allCases, id: \.self) { mode in
                Text(mode.label(agentId: controls.agentId)).tag(mode)
            }
        }
        .pickerStyle(.inline)
    }
}

/// "Select model": grouped models, then Effort and Ultracode rows (Claude's model sheet).
private struct ModelSheet: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let controls = store.controls(for: sessionId) {
                List {
                    if let model = controls.effortModel, !model.effortLevels.isEmpty {
                        Section {
                            EffortSlider(levels: model.effortLevels,
                                         selection: controls.effort ?? model.defaultEffort ?? model.effortLevels[0]) { level in
                                Task { await store.setEffort(level, in: sessionId) }
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                            if model.supportsUltracode {
                                Toggle(isOn: Binding(
                                    get: { controls.ultracode ?? false },
                                    set: { on in Task { await store.setUltracode(on, in: sessionId) } })
                                ) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Label("Ultracode", systemImage: "sparkles")
                                        Text("Maximum reasoning with dynamic workflows (forces XHigh effort).")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        row(id: "default", name: "Use CLI Settings",
                            detail: controls.appliedModelId.map { String(localized: "Running: \(controls.modelName($0))") } ?? String(localized: "Models configured in the CLI"),
                            selected: controls.selectedModelId == "default")
                        ForEach(controls.models) { model in
                            row(id: model.id, name: model.name, detail: model.description ?? model.id, selected: controls.selectedModelId == model.id)
                        }
                    } footer: {
                        if controls.agentId == "claude" { Text("Applies from your next message.") }
                    }
                }
                .navigationTitle("Select Model")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
            }
        }
    }

    private func row(id: String, name: String, detail: String, selected: Bool) -> some View {
        Button {
            Task { await store.setModel(id, in: sessionId) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.userBubble).fontWeight(.semibold) }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func effortName(_ level: String) -> String {
        switch level {
        case "xhigh": String(localized: "Extra High")
        case "max": String(localized: "Max")
        default: level.capitalized
        }
    }
}

/// ChatGPT-style effort control: the level's name on top of a capsule track with one stop per
/// level; the knob snaps between stops while dragging and commits on release.
private struct EffortSlider: View {
    let levels: [String]
    let selection: String
    let onCommit: (String) -> Void
    @State private var dragIndex: Int?

    private let knob: CGFloat = 40
    private let inset: CGFloat = 6

    private var index: Int { dragIndex ?? levels.firstIndex(of: selection) ?? 0 }

    var body: some View {
        VStack(spacing: 12) {
            Text(ModelSheet.effortName(levels[index]))
                .font(.title3.weight(.semibold))
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.15), value: index)
            GeometryReader { geo in
                let stops = stopPositions(width: geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.userBubble)
                        .frame(width: stops[index] + knob / 2 + inset, height: knob + inset * 2 - 4)
                        .padding(.leading, 2)
                    ForEach(levels.indices, id: \.self) { i in
                        Circle()
                            .fill(i <= index ? Color.white.opacity(0.55) : Color.secondary.opacity(0.6))
                            .frame(width: 8, height: 8)
                            .offset(x: stops[i] + knob / 2 - 4)
                    }
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        .offset(x: stops[index])
                }
                .frame(width: geo.size.width, height: knob + inset * 2, alignment: .leading)
                .glassEffect(.regular, in: Capsule())
                .contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let nearest = stops.indices.min { abs(stops[$0] + knob / 2 - value.location.x) < abs(stops[$1] + knob / 2 - value.location.x) } ?? 0
                        if nearest != dragIndex { withAnimation(.snappy(duration: 0.18)) { dragIndex = nearest } }
                    }
                    .onEnded { _ in
                        if let dragIndex, levels[dragIndex] != selection { onCommit(levels[dragIndex]) }
                        dragIndex = nil
                    })
                .sensoryFeedback(.selection, trigger: index)
                .animation(.snappy(duration: 0.2), value: index)
            }
            .frame(height: knob + inset * 2)
            .accessibilityElement()
            .accessibilityLabel("Effort")
            .accessibilityValue(ModelSheet.effortName(levels[index]))
            .accessibilityAdjustableAction { direction in
                let next = direction == .increment ? min(index + 1, levels.count - 1) : max(index - 1, 0)
                if next != index { onCommit(levels[next]) }
            }
        }
        .padding(.horizontal, 4)
    }

    /// Knob x-offset for each level, evenly spaced inside the track's insets.
    private func stopPositions(width: CGFloat) -> [CGFloat] {
        guard levels.count > 1 else { return [inset] }
        let span = width - knob - inset * 2
        return levels.indices.map { inset + span * CGFloat($0) / CGFloat(levels.count - 1) }
    }
}

// MARK: - Display helpers

private extension SessionControls {
    func modelName(_ id: String) -> String { models.first { $0.id == id }?.name ?? id }

    /// Model shown on the pill: explicit selection, else what the runtime reports, else the agent.
    var displayModelName: String {
        if selectedModelId != "default" { return modelName(selectedModelId) }
        if let applied = appliedModelId { return modelName(applied) }
        return agentId.flatMap { Agent.displayNames[$0] } ?? "Model"
    }

    /// The model whose effort levels apply: the selection, else the applied model.
    var effortModel: ModelChoice? {
        selectedModel ?? appliedModelId.flatMap { id in models.first { $0.id == id } }
    }

    var displayEffort: String? {
        guard let model = effortModel, !model.effortLevels.isEmpty else { return nil }
        return effort ?? model.defaultEffort
    }
}
