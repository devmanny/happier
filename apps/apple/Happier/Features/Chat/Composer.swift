import HappierKit
import os
import PhotosUI
import SwiftUI

/// Claude/ChatGPT-style composer with Happier's session controls: context chips (permission,
/// machine · folder, mode), a card with ⊕ options, the model pill, dictation and send/stop.
struct Composer: View {
    let sessionId: String
    @Binding var text: String
    /// Owned by the chat so files dropped anywhere on the conversation land here too.
    @Binding var attachments: [AttachmentDraft]
    let working: Bool
    let onSend: ([AttachmentDraft]) -> Void
    let onStop: () -> Void
    /// Opens the list of what runs in the background (presented by the conversation).
    var onShowActivity: () -> Void = {}

    private static let log = Logger(subsystem: "dev.happier.apple", category: "composer")
    @Environment(HappierStore.self) private var store
    @State private var sheet: SheetKind?
    @State private var dictation = Dictation()
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    #if os(iOS)
    @Environment(\.openURL) private var openURL
    @State private var showCamera = false
    @State private var showCameraPermission = false
    #endif
    @State private var focused = false
    @State private var editor = ComposerEditor()
    /// After sending during the keyboard's own dictation: what it still writes until then is dropped.
    @State private var discardDictationUntil: Date?
    /// The goal being written (Set Goal / Edit Goal).
    @State private var goalDraft: String?
    @State private var showPermissions = false
    @State private var mentioning = false
    /// The `@word` being typed, and the project's files to suggest for it.
    @State private var mentionQuery: String?
    @State private var fileResults: FileSuggestionResults = .loading
    #if os(macOS)
    @State private var paste = PasteShortcut()
    #endif

    enum SheetKind: Identifiable {
        case model
        var id: Self { self }
    }

    private var session: Session? { store.sessions[sessionId] }
    private var controls: SessionControls? { store.controls(for: sessionId) }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    private func add(_ drafts: [AttachmentDraft]) {
        AttachmentLoader.add(drafts, to: $attachments, store: store)
    }

    private func send() {
        guard canSend else { return }
        // Sending ends a dictation (the keyboard's Return as well as the send button).
        if dictation.isRecording { dictation.stop() }
        #if os(iOS)
        if focused, KeyboardDictation.isActive {
            // The keyboard's dictation keeps writing into the field after it is cleared, so the
            // last words of the message reappear. Ending the editing session stops it; what it
            // still delivers on the way out is dropped.
            focused = false
            discardDictationUntil = .now + 1.5
        }
        #endif
        let picked = attachments
        attachments = []
        onSend(picked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session, let goal = SessionGoal.current(in: session.metadata), goal.isOngoing {
                GoalChip(goal: goal, controls: SessionGoal.controls(agentState: session.agentState)) { action in
                    switch action {
                    case .edit: goalDraft = goal.objective
                    case .status(let status): Task { await store.setGoal(sessionId, status: status) }
                    case .clear: Task { await store.clearGoal(sessionId) }
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let stale = store.staleRunner(for: sessionId) {
                StaleRunnerBubble(updating: store.restartingRunners.contains(sessionId)) {
                    Task { await store.restartStaleRunner(stale.sessionId) }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let suggestions = slashSuggestions, !suggestions.isEmpty {
                SlashSuggestions(commands: suggestions) { insert($0) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if mentionQuery != nil, session?.machineId != nil, session?.path != nil {
                FileSuggestions(results: fileResults) { path in
                    editor.completeMention(path)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let session {
                statusRow(session)
            }
            card
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.smooth(duration: 0.2), value: slashSuggestions?.count)
        .animation(.smooth(duration: 0.25), value: store.staleRunner(for: sessionId) == nil)
        #if os(iOS)
        .sheet(item: $sheet) { kind in
            ModelPickerSheet { SessionModelPicker(sessionId: sessionId) }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { outcome in
                showCamera = false
                switch outcome {
                case .photo(let data): add([AttachmentLoader.photo(data)])
                case .cancelled: break
                case .failed: store.lastError = String(localized: "The photo couldn't be captured. Please try again.")
                }
            }
            .ignoresSafeArea()
        }
        .alert("Camera Access", isPresented: $showCameraPermission) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow camera access in Settings to take a photo and attach it to your message.")
        }
        #endif
        #if os(macOS)
        .onAppear {
            paste.install {
                let files = AttachmentLoader.clipboardFiles()
                add(files.isEmpty ? [AttachmentLoader.clipboardImage()].compactMap { $0 } : files)
            }
        }
        .onDisappear { paste.remove() }
        .onChange(of: focused, initial: true) { _, isFocused in paste.composerFocused = isFocused }
        #endif
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
        .alert("Goal", isPresented: Binding(get: { goalDraft != nil }, set: { if !$0 { goalDraft = nil } })) {
            TextField("What should the agent keep working toward?", text: Binding(get: { goalDraft ?? "" }, set: { goalDraft = $0 }), axis: .vertical)
            Button("Set Goal") {
                let objective = (goalDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                goalDraft = nil
                guard !objective.isEmpty else { return }
                Task { await store.setGoal(sessionId, objective: objective) }
            }
            Button("Cancel", role: .cancel) { goalDraft = nil }
        } message: {
            Text("The agent keeps pursuing it across turns until it's done.")
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
            ComposerTextField(
                text: $text,
                placeholder: String(localized: working ? "Steer or queue a message…" : "Describe a task or ask a question…"),
                isFocused: $focused,
                editor: editor,
                onSubmit: { send() },
                onPasteImages: { add($0) },
                onMentionQuery: { query in
                    withAnimation(.smooth(duration: 0.2)) { mentionQuery = query }
                }
            )
            .task(id: mentionQuery) {
                guard let query = mentionQuery else {
                    fileResults = .loading
                    return
                }
                guard let machineId = session?.machineId, let path = session?.path else { return }
                fileResults = await FileSuggestionResults.load(query, in: path, on: machineId, limit: 6, store: store) ?? fileResults
            }
            .padding(.horizontal, 6)
            .onChange(of: text) { _, new in
                if let until = discardDictationUntil, !focused, .now < until, !new.isEmpty {
                    Self.log.notice("dropped \(new.count, privacy: .public) characters of keyboard dictation after send")
                    text = ""
                }
            }

            HStack(spacing: 8) {
                AddMenu(canMention: session?.machineId != nil && session?.path != nil,
                        canSetGoal: session.map { SessionGoal.controls(agentState: $0.agentState).canSet } ?? false) {
                    if let draft = AttachmentLoader.clipboardImage() {
                        add([draft])
                    } else if let pasted = AttachmentLoader.clipboardText(), !pasted.isEmpty {
                        text += pasted
                        focused = true
                    }
                } onPhotos: {
                    showPhotos = true
                } onCamera: {
                    #if os(iOS)
                    Task {
                        guard CameraPicker.isAvailable else { return }
                        if await CameraPicker.requestAccess() {
                            showCamera = true
                        } else {
                            showCameraPermission = true
                        }
                    }
                    #endif
                } onFiles: {
                    showFiles = true
                } onMention: {
                    mentioning = true
                } onGoal: {
                    goalDraft = session.flatMap { SessionGoal.current(in: $0.metadata) }.flatMap { $0.isOngoing ? $0.objective : nil } ?? ""
                }
                .equatable()
                .sheet(isPresented: $mentioning) { mentionPicker }
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

    /// The status pill, and beside it what runs in the background.
    private func statusRow(_ session: Session) -> some View {
        // The daemon's count already includes active delegated runs; without it, add them up here.
        let running = session.reportsBackgroundActivity
            ? session.backgroundActivityCount
            : (store.transcripts[sessionId]?.subagents.filter { $0.status == .running }.count ?? 0)
                + (store.delegatedRuns[sessionId]?.filter(\.isActive).count ?? 0)
        return HStack(spacing: 6) {
            SessionStatusRow(session: session)
            if running > 0 {
                BackgroundActivityPill(count: running) {
                    Self.log.notice("background pill tapped (\(running, privacy: .public) running)")
                    onShowActivity()
                }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.25), value: running > 0)
    }

    @ViewBuilder private var mentionPicker: some View {
        if let machineId = session?.machineId, let root = session?.path {
            FileMentionPicker(machineId: machineId, root: root) { path in
                // A pill where the cursor is; without the field on screen, a token at the end.
                if !editor.insertMention(path) { text = FileMention.appending(path, to: text) }
                focused = true
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 520)
            #endif
        }
    }

    private func modelPill(_ controls: SessionControls) -> some View {
        Button {
            sheet = .model
        } label: {
            HStack(spacing: 5) {
                if let armed = store.armedAgents[sessionId] {
                    // The next message switches the session to this agent.
                    Image(systemName: "arrow.triangle.swap").foregroundStyle(Color.userBubble)
                    Text(SessionModelPicker.label(armed, sessions: Array(store.sessions.values))).lineLimit(1)
                } else {
                    Text(controls.displayModelName).lineLimit(1)
                    if let effort = controls.displayEffort {
                        Text(EffortSlider.name(effort)).foregroundStyle(.secondary)
                    }
                }
                #if os(macOS)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                #endif
            }
            .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Model")
        #if os(macOS)
        .popover(isPresented: Binding(get: { sheet == .model }, set: { if !$0 { sheet = nil } }), arrowEdge: .top) {
            ModelPopover(sessionId: sessionId)
        }
        #endif
    }

    @ViewBuilder
    private func permissionPill(_ controls: SessionControls) -> some View {
        let label = controls.permissionMode.label(agentId: controls.agentId)
        #if os(macOS)
        // A Mac menu flattens its label (its own image placement, no background), so the pill is a
        // glass button like the model's, opening the choices beside it.
        Button { showPermissions = true } label: {
            HStack(spacing: 5) {
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.glass)
        .fixedSize()
        .accessibilityLabel("Permission mode")
        .popover(isPresented: $showPermissions, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Button {
                        showPermissions = false
                        Task { await store.setPermissionMode(mode, in: sessionId) }
                    } label: {
                        HStack {
                            Text(mode.label(agentId: controls.agentId))
                            Spacer(minLength: 16)
                            if mode == controls.permissionMode {
                                Image(systemName: "checkmark").foregroundStyle(Color.userBubble)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 200)
        }
        #else
        PermissionMenu(label: label, mode: controls.permissionMode, agentId: controls.agentId) { mode in
            Task { await store.setPermissionMode(mode, in: sessionId) }
        }
        .equatable()
        #endif
    }

    @ViewBuilder private var sendButton: some View {
        let stop = working && !canSend
        Button {
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

/// How the session is doing, just above the composer like the official app: a pill colored by the
/// state (green online, blue working, orange waiting on you, red failed, brown archived, gray
/// inactive), as wide as what it says.
private struct SessionStatusRow: View {
    let session: Session

    private struct Look {
        let text: LocalizedStringKey
        var icon: String?
        var tint: Color?
        var detail: Text?
        var spinning = false
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let look = look(status: session.status(at: context.date))
            HStack(spacing: 5) {
                // The state's color is in the mark; the pill only takes a hint of it.
                Group {
                    if look.spinning {
                        HappierSpinner(size: HappierSpinner.mini, color: look.tint)
                    } else if let icon = look.icon {
                        Image(systemName: icon)
                    } else {
                        Circle().frame(width: 7, height: 7)
                    }
                }
                .foregroundStyle(look.tint ?? .secondary)
                Text(look.text)
                    .foregroundStyle(look.tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if let detail = look.detail {
                    detail.foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(look.tint.map { .regular.tint($0.opacity(0.28)) } ?? .regular, in: Capsule())
            .animation(.smooth(duration: 0.25), value: session.status(at: context.date))
            .animation(.smooth(duration: 0.25), value: session.archivedAt)
        }
    }

    private func look(status: Session.Status) -> Look {
        if session.archivedAt != nil {
            return Look(text: "Archived", icon: "archivebox.fill", tint: .brown, detail: Text("· sending a message brings it back"))
        }
        switch status {
        case .working: return Look(text: "Working", tint: .userBubble, spinning: true)
        case .permissionRequired: return Look(text: "Needs your approval", icon: "hand.raised.fill", tint: .orange)
        case .actionRequired: return Look(text: "Waiting for your answer", icon: "questionmark.bubble.fill", tint: .orange)
        case .failed: return Look(text: "Turn failed", icon: "exclamationmark.triangle.fill", tint: .red)
        case .idle: return Look(text: "Online", tint: .green)
        case .offline:
            return Look(text: "Inactive", detail: session.activeAt.map { Text("· active \($0, format: .relative(presentation: .named))") })
        }
    }
}

/// A round glass control of the composer (mic, dictation): prominent blue while active.
struct CircleButton: View {
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

/// Files of the project matching the `@word` being typed, above the composer; picking one turns
/// the word into a pill. A spinner while the project is listed.
/// What the `@` suggestions show: the first listing on its way, the matches, or why the
/// project's files couldn't be listed.
enum FileSuggestionResults: Equatable {
    case loading
    case found([String])
    case failed(String)

    /// The matches for what's typed after a short pause (typing on cancels it); nil when cancelled.
    @MainActor
    static func load(_ query: String, in path: String, on machineId: String, limit: Int, store: HappierStore) async -> Self? {
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return nil }
        let results: Self
        do {
            results = .found(try await store.fileSuggestions(in: path, on: machineId, query: query, limit: limit))
        } catch {
            results = .failed(error.localizedDescription)
        }
        return Task.isCancelled ? nil : results
    }

    /// A suggestion's name (folders keep their trailing `/`) and the folder it's in.
    static func label(_ path: String) -> (name: String, folder: String, isFolder: Bool) {
        let isFolder = path.hasSuffix("/")
        let trimmed = isFolder ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent + (isFolder ? "/" : "")
        return (name, (trimmed as NSString).deletingLastPathComponent, isFolder)
    }
}

private struct FileSuggestions: View {
    let results: FileSuggestionResults
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch results {
            case .loading:
                HappierSpinner(size: HappierSpinner.mini)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            case .failed(let message):
                Label {
                    Text("Couldn't list this project's files. \(message)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            case .found(let paths):
                if paths.isEmpty {
                    Text("No matching files")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                ForEach(paths, id: \.self) { path in
                    let label = FileSuggestionResults.label(path)
                    Button {
                        onSelect(path)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: label.isFolder ? "folder.fill" : "doc.text")
                                .foregroundStyle(label.isFolder ? Color.accentColor : .secondary)
                            Text(label.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(label.folder)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

/// The ⊕ menu: paste, camera, photos and files, mentions, and the goal. Compared by its displayed
/// options so unrelated session updates don't rebuild the menu while it is open.
private struct AddMenu: View, Equatable {
    let canMention: Bool
    let canSetGoal: Bool
    let onPaste: () -> Void
    let onPhotos: () -> Void
    let onCamera: () -> Void
    let onFiles: () -> Void
    let onMention: () -> Void
    let onGoal: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canMention == rhs.canMention && lhs.canSetGoal == rhs.canSetGoal
    }

    var body: some View {
        Menu {
            Button("Paste", systemImage: "doc.on.clipboard", action: onPaste)
            Button("Photo or Video", systemImage: "photo.on.rectangle", action: onPhotos)
            #if os(iOS)
            if CameraPicker.isAvailable {
                Button("Take Photo", systemImage: "camera", action: onCamera)
            }
            #endif
            Button("File", systemImage: "doc", action: onFiles)
            if canMention {
                Divider()
                Button(action: onMention) {
                    Label {
                        Text("Mention a File")
                        Text("Point the agent at a file of the project")
                    } icon: {
                        Image(systemName: "at")
                    }
                }
            }
            if canSetGoal {
                Divider()
                Button(action: onGoal) {
                    Label {
                        Text("Goal")
                        Text("Set a goal to keep pursuing")
                    } icon: {
                        Image(systemName: "scope")
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: 22, height: 22)
        }
        // The same glass disc as the mic and send buttons beside it, on every platform.
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .fixedSize()
        .accessibilityLabel("Add")
    }
}

#if os(iOS)
/// The permission pill's menu, compared by what it shows (see `AddMenu`).
private struct PermissionMenu: View, Equatable {
    let label: String
    let mode: PermissionMode
    let agentId: String?
    let onSelect: (PermissionMode) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.label == rhs.label && lhs.mode == rhs.mode && lhs.agentId == rhs.agentId
    }

    var body: some View {
        Menu {
            Picker("Permissions", selection: Binding(get: { mode }, set: { onSelect($0) })) {
                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    Text(mode.label(agentId: agentId)).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(label)
                .lineLimit(1)
                .font(.subheadline.weight(.medium))
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Permission mode")
    }
}
#endif

/// ChatGPT-style effort control: the level's name on top of a capsule track with one stop per
/// level; the knob snaps between stops while dragging and commits on release.
struct EffortSlider: View {
    let levels: [String]
    let selection: String
    let onCommit: (String) -> Void
    @State private var dragIndex: Int?

    static func name(_ level: String) -> String {
        switch level {
        case "xhigh": String(localized: "Extra High")
        case "max": String(localized: "Max")
        default: level.capitalized
        }
    }

    #if os(macOS)
    // A pointer needs far less than a finger: a slim track, like the desktop ChatGPT and Codex.
    private let knob: CGFloat = 18
    private let inset: CGFloat = 3
    private let dot: CGFloat = 4
    private let titleFont = Font.headline
    #else
    private let knob: CGFloat = 40
    private let inset: CGFloat = 6
    private let dot: CGFloat = 8
    private let titleFont = Font.title3.weight(.semibold)
    #endif

    private var index: Int { dragIndex ?? levels.firstIndex(of: selection) ?? 0 }

    var body: some View {
        VStack(spacing: knob < 30 ? 8 : 12) {
            Text(Self.name(levels[index]))
                .font(titleFont)
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
                            .frame(width: dot, height: dot)
                            .offset(x: stops[i] + knob / 2 - dot / 2)
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
                        if nearest != dragIndex {
                            withAnimation(.snappy(duration: 0.18)) { dragIndex = nearest }
                        }
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
            .accessibilityValue(Self.name(levels[index]))
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

#if os(macOS)
/// The desktop popover: the same agent → model → effort picker as the iPhone sheet.
private struct ModelPopover: View {
    let sessionId: String

    var body: some View {
        SessionModelPicker(sessionId: sessionId)
            .frame(width: 340, height: 520)
    }
}
#endif

// MARK: - Display helpers

extension SessionControls {
    func modelName(_ id: String) -> String { models.first { $0.id == id }?.name ?? (effortModel?.id == id ? effortModel?.name : nil) ?? id }

    /// Model shown on the pill: explicit selection, else what the runtime reports, else the agent.
    var displayModelName: String {
        if selectedModelId != "default" { return modelName(selectedModelId) }
        if let applied = appliedModelId { return modelName(applied) }
        return agentId.flatMap { Agent.displayNames[$0] } ?? "Model"
    }

}

/// Shown only while the session's runner is on an older CLI than its daemon; tapping restarts it on
/// the current CLI (the conversation is kept) and the bubble goes away once it has been replaced.
private struct StaleRunnerBubble: View {
    let updating: Bool
    let onUpdate: () -> Void

    var body: some View {
        Button(action: onUpdate) {
            HStack(spacing: 6) {
                if updating {
                    HappierSpinner(size: HappierSpinner.mini, color: .orange)
                    Text("Updating to the new CLI…")
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Older CLI · Update")
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.orange)
        }
        // Amber glass: a gentle heads-up, not an error.
        .buttonStyle(.glass(.regular.tint(.orange.opacity(0.22))))
        .controlSize(.small)
        .disabled(updating)
        .accessibilityHint(Text("Restarts this session on the CLI the computer now runs. The conversation is kept."))
    }
}

#if os(iOS)
/// The system keyboard's dictation (its mic key), as opposed to the composer's own mic.
@MainActor
enum KeyboardDictation {
    /// While it listens, the editing field's input mode reports the "dictation" language.
    static var isActive: Bool {
        UIResponder.current?.textInputMode?.primaryLanguage == "dictation"
    }
}

private extension UIResponder {
    private static weak var found: UIResponder?

    /// The first responder, found by sending an action down the responder chain.
    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.reportAsFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    @objc func reportAsFirstResponder() {
        UIResponder.found = self
    }
}
#endif

#if os(macOS)
/// ⌘V in the composer attaches copied files or an image; text still pastes as usual. The text
/// field only takes text, so without this an image on the clipboard pastes nothing.
@MainActor
final class PasteShortcut {
    var composerFocused = false
    private var monitor: Any?

    func install(_ attach: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.composerFocused,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  AttachmentLoader.clipboardHasAttachments else { return event }
            attach()
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif

/// The goal the agent is pursuing, above the composer: tap for pause/resume, done, edit and clear.
private struct GoalChip: View {
    enum Action { case edit, status(SessionGoal.Status), clear }

    let goal: SessionGoal
    let controls: SessionGoal.Controls
    let perform: (Action) -> Void

    var body: some View {
        Menu {
            if controls.canSet {
                if goal.status == .paused {
                    Button("Resume", systemImage: "play") { perform(.status(.active)) }
                } else {
                    Button("Pause", systemImage: "pause") { perform(.status(.paused)) }
                }
                Button("Mark as Done", systemImage: "checkmark.circle") { perform(.status(.complete)) }
                Button("Edit Goal…", systemImage: "pencil") { perform(.edit) }
            }
            if controls.canClear {
                Button("Clear Goal", systemImage: "xmark.circle", role: .destructive) { perform(.clear) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .foregroundStyle(Color.userBubble)
                Text(goal.objective)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let state = stateLabel {
                    Text(state)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(Text("Goal: \(goal.objective)"))
    }

    private var stateLabel: String? {
        switch goal.status {
        case .paused: String(localized: "Paused")
        case .blocked: String(localized: "Blocked")
        case .pending: String(localized: "Pending")
        default: nil
        }
    }
}
