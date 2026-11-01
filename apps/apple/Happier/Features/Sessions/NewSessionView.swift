import HappierKit
import SwiftUI

/// The selection that shows a new, empty conversation instead of a session.
enum NewChat {
    static let id = "happier.new-chat"
}

/// A new session as an empty conversation (ChatGPT, Claude): the first message is written in a
/// composer whose pills choose the agent and model, effort, permissions, machine and folder;
/// sending it starts the agent there (the daemon's `spawn-happy-session`).
struct NewSessionView: View {
    let draft: NewSessionDraft?
    var onCreated: ((String) -> Void)?
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var machineId: String?
    @State private var directory = ""
    @State private var agentId = "claude"
    @State private var modelId = "default"
    @State private var effort: String?
    @State private var permissionMode: PermissionMode = .yolo
    /// The agent last started from here; its model and effort are remembered per agent.
    @AppStorage(NewSessionDefaults.agentKey) private var lastAgentId = ""
    @State private var firstMessage = ""
    @State private var starting = false
    @State private var error: String?
    @State private var folderToApprove: String?
    @State private var showBrowser = false
    @State private var showModelPicker = false
    @State private var dictation = Dictation()
    @State private var talking = false
    @State private var talkCancelArmed = false
    @State private var textBeforeTalking = ""
    @State private var trashX: CGFloat?
    @State private var micX: CGFloat?
    @State private var attachments: [AttachmentDraft] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var showCameraPermission = false
    @State private var messageFocused = false
    @State private var editor = ComposerEditor()
    /// The `@word` being typed, for the file suggestions above the composer.
    @State private var mentionQuery: String?
    @State private var fileResults: FileSuggestionResults = .loading
    @State private var mentioning = false
    /// A goal chosen before starting; set on the session before its first message.
    @State private var goal: String?
    @State private var goalDraft: String?
    @State private var parentName: String

    init(draft: NewSessionDraft? = nil, onCreated: ((String) -> Void)? = nil) {
        self.draft = draft
        self.onCreated = onCreated
        _machineId = State(initialValue: draft?.machineId)
        _directory = State(initialValue: draft?.directory ?? "")
        _parentName = State(initialValue: draft?.group?.suggestedTitle ?? "")
    }

    private var machine: Machine? { store.machines.first { $0.id == machineId } }

    private var recentDirectories: [String] {
        machineId.map { Machine.recentDirectories(machineId: $0, sessions: Array(store.sessions.values)) } ?? []
    }

    /// The agents installed on the chosen machine, most used first (a new one included once it's
    /// installed). Until the machine answers, or if it can't, the agents you already use.
    private var agents: [String] {
        var counts: [String: Int] = [:]
        for session in store.sessions.values { if let id = session.agentId { counts[id, default: 0] += 1 } }
        let used = counts.sorted { $0.value > $1.value }.map(\.key)
        var seen = Set<String>()
        let candidates = installed.map { installed in ([lastAgentId] + used + Agent.ids).filter(installed.contains) }
            ?? ([lastAgentId] + used + ["claude", "codex"])
        return candidates.filter { !$0.isEmpty && $0 != "customAcp" && seen.insert($0).inserted }
    }

    /// What the chosen machine has installed (nil until it answers).
    @State private var installed: Set<String>?

    private var models: [ModelChoice] { SessionControls.newSessionModels(agentId: agentId, sessions: Array(store.sessions.values)) }
    private var effortLevels: [String] { models.first { $0.id == modelId }?.effortLevels ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            // Keep the assistant centered when it fits; with a keyboard or a small window,
            // its heading and parent name scroll while the composer stays reachable below.
            ScrollView {
                VStack(spacing: 12) {
                    // The agent's logo is also its picker: the same choices as the composer pill.
                    Button {
                        AppHaptics.light()
                        showModelPicker = true
                    } label: {
                        AgentAvatar(agentId: agentId, size: 64, interactive: true)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(Text("Agent"))
                    Text(draft?.group == nil ? "What should we work on?" : "New Parent Session")
                        .font(.title2.weight(.semibold))
                    if draft?.group != nil {
                        TextField("Name", text: $parentName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("new-parent-session-name")
                            .frame(maxWidth: 440)
                        Text("Choose the agent and model for the session that will hold both conversations.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Text(placeLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .defaultScrollAnchor(.center, for: .alignment)
            .frame(maxHeight: .infinity)
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            // Where it runs, chosen first: the machine, then its folder, just above the composer.
            HStack(spacing: 8) {
                machineMenu
                folderMenu
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            if mentionQuery != nil, machineId != nil, !directory.isEmpty {
                FileSuggestions(results: fileResults) { path in editor.completeMention(path) }
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            composer
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .animation(.smooth(duration: 0.2), value: mentionQuery != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(AttachmentSources(showPhotos: $showPhotos, showFiles: $showFiles, showCamera: $showCamera,
                                    showCameraPermission: $showCameraPermission) { add($0) })
        // Files dropped anywhere on the empty chat go with the first message, as in a conversation.
        .dropDestination(for: DroppedAttachment.self) { items, _ in
            let files = items.map(\.draft).filter { !SessionDrag.isPayload($0.data) }
            add(files)
            return !files.isEmpty
        }
        .navigationTitle(draft?.group == nil ? "New Session" : "New Parent Session")
        .interactiveDismissDisabled(starting)
        .toolbar {
            if onCreated != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(starting)
                }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: agentId, initial: true) { _, agent in
            restoreChoices(for: agent)
            applyDefaultPermissionMode(for: agent)
            if !SessionGoal.supported(agentId: agent, sessions: Array(store.sessions.values)) { goal = nil }
        }
        .alert("Goal", isPresented: Binding(get: { goalDraft != nil }, set: { if !$0 { goalDraft = nil } })) {
            TextField("What should the agent keep working toward?", text: Binding(get: { goalDraft ?? "" }, set: { goalDraft = $0 }), axis: .vertical)
            Button("Set Goal") {
                let objective = (goalDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                goalDraft = nil
                AppHaptics.confirm()
                withAnimation(.smooth) { goal = objective.isEmpty ? nil : objective }
            }
            Button("Cancel", role: .cancel) { goalDraft = nil }
        } message: {
            Text("The agent keeps pursuing it across turns until it's done.")
        }
        .onChange(of: modelId) { _, _ in fitEffort() }
        .onChange(of: dictation.error) { _, error in
            if let error {
                talking = false
                talkCancelArmed = false
                AppHaptics.error()
                store.lastError = error
            }
        }
        .onDisappear {
            // A dismissed wizard must not leave its mic running or start it after permission UI.
            if talking { stopTalking(cancelled: true) } else { dictation.stop() }
        }
        .alert("Create Folder?", isPresented: Binding(get: { folderToApprove != nil }, set: { if !$0 { folderToApprove = nil } })) {
            Button("Create and Start") { start(approve: true) }
            Button("Cancel", role: .cancel) { AppHaptics.light() }
        } message: {
            Text("\(folderToApprove ?? "") doesn't exist on \(machine?.name ?? "the machine") yet.")
        }
        .task {
            await store.refreshMachines()
            if machineId == nil, let first = store.machines.first(where: \.active) ?? store.machines.first {
                machineId = first.id
                directory = Machine.recentDirectories(machineId: first.id, sessions: Array(store.sessions.values)).first ?? first.homeDir ?? ""
            }
            if let preferred = agents.first { agentId = preferred }
            messageFocused = true
            // The per-agent default chosen in Settings (or the React Native app).
            if store.accountSettings == nil { await store.refreshAccountSettings() }
            applyDefaultPermissionMode(for: agentId)
        }
        .task(id: machineId) {
            guard let machineId else { return }
            installed = nil
            installed = await store.installedAgents(on: machineId)
            // The picked agent isn't on this machine: the first one that is.
            if let installed, !installed.contains(agentId), let first = agents.first { agentId = first }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet {
                AgentModelPicker(
                    agents: agents,
                    choice: Binding(
                        get: { AgentModelChoice(agentId: agentId, modelId: modelId, effort: effort) },
                        set: { next in
                            // The agent's remembered model and effort come back through `restoreChoices`.
                            if next.agentId != agentId { agentId = next.agentId; return }
                            modelId = next.modelId
                            effort = next.effort
                        }),
                    models: { agent in SessionControls.newSessionModels(agentId: agent, sessions: Array(store.sessions.values)) },
                    footer: String(localized: "The conversation starts with this agent and model."))
            }
            #if os(macOS)
            .frame(minWidth: 380, minHeight: 520)
            #else
            .presentationDetents([.medium, .large])
            #endif
        }
        .sheet(isPresented: $showBrowser) {
            if let machine {
                FolderBrowserView(machine: machine, recents: recentDirectories) { path in directory = path }
                    #if os(macOS)
                    .frame(minWidth: 460, minHeight: 560)
                    #endif
            }
        }
    }

    /// "Abundia-mini · ~/Projects/radar".
    private var placeLine: String {
        [machine?.name, directory.isEmpty ? nil : displayPath(directory)].compactMap { $0 }.joined(separator: " · ")
    }

    private func startTalking() {
        guard !talking, !starting else { return }
        textBeforeTalking = firstMessage
        talkCancelArmed = false
        talking = true
        MessageSpeaker.shared.stop()
        Task {
            guard talking else { return }
            await dictation.begin(prefix: firstMessage) { firstMessage = $0 }
        }
    }

    private func stopTalking(cancelled: Bool) {
        guard talking else { return }
        if cancelled {
            dictation.stop()
            firstMessage = textBeforeTalking
            talking = false
            talkCancelArmed = false
            AppHaptics.listening(false, cancelled: true)
            return
        }
        AppHaptics.listening(false)
        Task {
            await dictation.finish()
            talking = false
            talkCancelArmed = false
            // Keep the first message for review. Only Send creates the session.
        }
    }

    private var canStart: Bool {
        !starting && machineId != nil && machine?.active == true
            && !directory.trimmingCharacters(in: .whitespaces).isEmpty
            && (draft?.group != nil || !firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func add(_ drafts: [AttachmentDraft]) {
        AttachmentLoader.add(drafts, to: $attachments, store: store)
    }

    /// The message and, as pills under it, where and with what it starts: agent and model first.
    /// The same card as a live conversation's composer (`Composer.card`).
    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments)
            }
            if let goal {
                // The goal it will start with, removable before sending.
                HStack(spacing: 6) {
                    Image(systemName: "scope").foregroundStyle(Color.userBubble)
                    Text(goal).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Remove Goal", systemImage: "xmark.circle.fill") { withAnimation(.smooth) { self.goal = nil } }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.pressable)
                }
                .font(.footnote)
                .padding(.horizontal, 6)
            }
            // The live conversation's own field: @ suggests the folder's files, pasted images attach.
            ComposerTextField(
                text: $firstMessage,
                placeholder: String(localized: "Describe a task or ask a question…"),
                isFocused: $messageFocused,
                editor: editor,
                onSubmit: { if canStart { start(approve: false) } },
                onPasteImages: { add($0) },
                onMentionQuery: { query in withAnimation(.smooth(duration: 0.2)) { mentionQuery = query } }
            )
            .task(id: mentionQuery) {
                guard let query = mentionQuery else {
                    fileResults = .loading
                    return
                }
                guard let machineId, !directory.isEmpty else { return }
                fileResults = await FileSuggestionResults.load(query, in: directory, on: machineId, limit: 6, store: store) ?? fileResults
            }
            .padding(.horizontal, 6)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    // The live composer's ⊕ menu: mentions and a goal, files, photos and the camera.
                    AddMenu(canMention: machineId != nil && !directory.isEmpty,
                            canSetGoal: SessionGoal.supported(agentId: agentId, sessions: Array(store.sessions.values))) {
                        if let draft = AttachmentLoader.clipboardImage() {
                            add([draft])
                        } else if let pasted = AttachmentLoader.clipboardText(), !pasted.isEmpty {
                            firstMessage += pasted
                            messageFocused = true
                        }
                    } onPhotos: {
                        showPhotos = true
                    } onCamera: {
                        AttachmentSources.openCamera(show: $showCamera, denied: $showCameraPermission)
                    } onFiles: {
                        showFiles = true
                    } onMention: {
                        mentioning = true
                    } onGoal: {
                        goalDraft = goal ?? ""
                    }
                    .equatable()
                    .sheet(isPresented: $mentioning) {
                        if let machineId {
                            FileMentionPicker(machineId: machineId, root: directory) { path in
                                if !editor.insertMention(path) { firstMessage = FileMention.appending(path, to: firstMessage) }
                                messageFocused = true
                            }
                            #if os(macOS)
                            .frame(minWidth: 460, minHeight: 520)
                            #endif
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            agentMenu
                            permissionMenu
                        }
                    }
                    .scrollClipDisabled()
                }
                .opacity(talking ? 0 : 1)
                .allowsHitTesting(!talking)
                .accessibilityHidden(talking)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX + TalkPanel.trashCenter } action: { trashX = $0 }
                .overlay {
                    if talking {
                        TalkPanel(levels: dictation.levels, cancelArmed: talkCancelArmed)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                // The mic while there is nothing to send, as in a live conversation's composer.
                if firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dictation.isRecording || talking {
                    PushToTalkButton(recording: dictation.isRecording, talking: talking, cancelArmed: $talkCancelArmed,
                                     trashOffset: trashX.flatMap { trash in micX.map { trash - $0 } },
                                     holdHint: "Hold to talk; release to keep text") {
                        AppHaptics.light()
                        dictation.toggle(prefix: firstMessage) { firstMessage = $0 }
                    } onHoldStart: {
                        startTalking()
                    } onHoldEnd: { cancelled in
                        stopTalking(cancelled: cancelled)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { micX = $0 }
                    .disabled(starting)
                }
                Button { start(approve: false) } label: {
                    Group {
                        if starting {
                            HappierSpinner(size: HappierSpinner.mini, color: .white)
                        } else {
                            Image(systemName: "arrow.up").font(.body.weight(.bold))
                        }
                    }
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.glassProminent)
                .glassHover()
                .buttonBorderShape(.circle)
                .tint(.userBubble)
                .disabled(!canStart)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(draft?.group == nil ? "Send" : "Create Parent Session")
                // Keep its space while held so the mic stays under the finger.
                .opacity(talking ? 0 : 1)
                .allowsHitTesting(!talking)
                .accessibilityHidden(talking)
            }
            .animation(.smooth(duration: 0.2), value: talking)
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    /// Agent, model and effort: opens the same picker as a live session's model pill.
    private var agentMenu: some View {
        Button {
            AppHaptics.light()
            showModelPicker = true
        } label: {
            chip {
                Image("Agents/\(agentId)").resizable().scaledToFit().frame(width: 15, height: 15)
                Text(agentLabel).lineLimit(1)
            }
        }
        .buttonStyle(.glass)
        .glassHover()
        .accessibilityLabel("Model")
    }

    /// "Opus 5.5 · High": the model and, when it has levels, its effort.
    private var agentLabel: String {
        let agent = Agent.displayNames[agentId] ?? agentId
        guard modelId != "default", let model = models.first(where: { $0.id == modelId }) else { return agent }
        guard !model.effortLevels.isEmpty else { return model.name }
        return "\(model.name) · \(EffortSlider.name(effort ?? model.defaultEffort ?? model.effortLevels[0]))"
    }

    private var permissionMenu: some View {
        Menu {
            ForEach(PermissionMode.allCases, id: \.self) { mode in
                Button {
                    if permissionMode != mode { AppHaptics.selection() }
                    permissionMode = mode
                } label: { checked(mode.label(agentId: agentId), mode == permissionMode) }
            }
        } label: {
            chip { Text(permissionMode.label(agentId: agentId)) }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .glassHover()
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Permission mode")
    }

    private var machineMenu: some View {
        Menu {
            ForEach(store.machines) { item in
                Button {
                    AppHaptics.selection()
                    machineId = item.id
                    directory = Machine.recentDirectories(machineId: item.id, sessions: Array(store.sessions.values)).first ?? item.homeDir ?? ""
                } label: {
                    checked(item.name + (item.active ? "" : String(localized: " (offline)")), item.id == machineId)
                }
            }
        } label: {
            chip {
                Image(systemName: "desktopcomputer")
                Text(machine?.name ?? String(localized: "Machine")).lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .glassHover()
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var folderMenu: some View {
        Menu {
            ForEach(recentDirectories.prefix(8), id: \.self) { path in
                Button {
                    if directory != path { AppHaptics.selection() }
                    directory = path
                } label: { checked(displayPath(path), path == directory) }
            }
            Divider()
            Button("Browse Folders…", systemImage: "folder.badge.gearshape") {
                AppHaptics.light()
                showBrowser = true
            }
                .disabled(machine?.active != true)
        } label: {
            chip {
                Image(systemName: "folder")
                Text(directory.isEmpty ? String(localized: "Folder") : (directory as NSString).lastPathComponent).lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .glassHover()
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// A glass button's label, set like the live composer's pills (the `.glass` style draws the capsule).
    private func chip(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 5) { content() }
            .font(.subheadline.weight(.medium))
    }

    private func start(approve: Bool) {
        guard let machineId else { return }
        // Sending ends a dictation, as in a live conversation.
        if dictation.isRecording { dictation.stop() }
        AppHaptics.confirm()
        starting = true
        error = nil
        let path = directory.trimmingCharacters(in: .whitespaces)
        rememberChoices()
        let effort = effortLevels.isEmpty ? nil : effort
        Task {
            let outcome = await store.createSession(machineId: machineId, directory: path, agentId: agentId, permissionMode: permissionMode,
                                                    modelId: modelId, effort: effort, firstMessage: firstMessage,
                                                    attachments: attachments, goal: goal, approveNewDirectory: approve,
                                                    grouping: draft?.group, title: parentName)
            starting = false
            switch outcome {
            case .created(let sessionId):
                AppHaptics.success()
                firstMessage = ""
                attachments = []
                goal = nil
                onCreated?(sessionId)
            case .needsDirectoryApproval(let folder):
                AppHaptics.warning()
                folderToApprove = folder
            case .failed(let message):
                AppHaptics.error()
                error = message
            }
        }
    }

    // MARK: Remembered model and effort

    private static func modelKey(_ agent: String) -> String { NewSessionDefaults.modelKey(agent) }
    private static func effortKey(_ agent: String) -> String { NewSessionDefaults.effortKey(agent) }

    /// The model and effort last started with this agent, while it still offers them.
    /// The account's default permission mode for this agent, when the user chose one.
    private func applyDefaultPermissionMode(for agent: String) {
        if let mode = store.accountSettings?.defaultPermissionMode(for: agent) { permissionMode = mode }
    }

    private func restoreChoices(for agent: String) {
        let defaults = UserDefaults.standard
        let remembered = defaults.string(forKey: Self.modelKey(agent))
        modelId = remembered.flatMap { id in models.contains { $0.id == id } ? id : nil } ?? "default"
        effort = defaults.string(forKey: Self.effortKey(agent))
        fitEffort()
    }

    /// Keeps the effort when the model offers it; otherwise the model's own default.
    private func fitEffort() {
        let model = models.first { $0.id == modelId }
        guard let levels = model?.effortLevels, !levels.isEmpty else { return }
        if effort.map(levels.contains) != true { effort = model?.defaultEffort ?? levels[0] }
    }

    private func rememberChoices() {
        lastAgentId = agentId
        let defaults = UserDefaults.standard
        defaults.set(modelId, forKey: Self.modelKey(agentId))
        if !effortLevels.isEmpty, let effort { defaults.set(effort, forKey: Self.effortKey(agentId)) }
    }

    private func displayPath(_ path: String) -> String {
        if let home = machine?.homeDir, path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// Contextual creation uses the complete assistant while keeping the existing conversation in
/// place. Cancel only dismisses this draft; sending follows the same creation path as New Session.
struct NewSessionSheet: View {
    let draft: NewSessionDraft
    var onCreated: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NewSessionView(draft: draft) { sessionId in
                dismiss()
                onCreated?(sessionId)
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 560)
        #endif
    }
}
