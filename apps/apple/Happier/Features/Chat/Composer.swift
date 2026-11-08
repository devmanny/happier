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
    /// Dragging the status line (see `statusDrag`).
    @State private var statusGrabbed = false
    @State private var statusDragX: CGFloat = 0
    @State private var statusPillWidth: CGFloat = 0
    @State private var statusRowWidth: CGFloat = 0
    @State private var droppedSide: AccountSettings.StatusPosition?
    /// The agent card, opened by tapping the status pill.
    @State private var showAgentCard = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dictation = Dictation()
    @State private var showPhotos = false
    @State private var showFiles = false
    // Only iOS has a camera to open; the pickers take these everywhere.
    /// Holding the mic: push to talk.
    @State private var talking = false
    /// The held mic is stuck to the trash: letting go deletes what was said.
    @State private var talkCancelArmed = false
    /// The trash's and the mic's centers across the window, for the mic to stick to the trash.
    @State private var trashX: CGFloat?
    @State private var micX: CGFloat?
    @State private var textBeforeTalking = ""
    @State private var showCamera = false
    @State private var showCameraPermission = false
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

    /// Push to talk: what's being read stops so you can speak, and from now on the agent's
    /// answers in this conversation are read aloud.
    private func startTalking() {
        guard !talking else { return }
        textBeforeTalking = text
        talkCancelArmed = false
        talking = true
        if MessageSpeaker.shared.autoReadSessionId != sessionId {
            MessageSpeaker.shared.toggleAutoRead(sessionId, store: store)
        }
        Task {
            guard talking else { return }
            await dictation.begin(prefix: text) { text = $0 }
        }
    }

    /// Released: the last words come in, then it's sent; slid onto the trash, nothing is sent
    /// and the field is as it was.
    private func stopTalking(cancelled: Bool) {
        if cancelled {
            dictation.stop()
            text = textBeforeTalking
            talking = false
            talkCancelArmed = false
            AppHaptics.listening(false, cancelled: true)
            return
        }
        AppHaptics.listening(false)
        Task {
            await dictation.finish()
            guard talking else { return }
            talking = false
            if canSend { send() }
        }
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
        AppHaptics.confirm()
        onSend(picked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session, let goal = SessionGoal.current(in: session.metadata), goal.isOngoing {
                GoalChip(goal: goal, controls: SessionGoal.controls(agentState: session.agentState)) { action in
                    switch action {
                    case .edit:
                        AppHaptics.light()
                        goalDraft = goal.objective
                    case .status(let status):
                        AppHaptics.confirm()
                        Task { await store.setGoal(sessionId, status: status) }
                    case .clear:
                        AppHaptics.warning()
                        Task { await store.clearGoal(sessionId) }
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let stale = store.staleRunner(for: sessionId) {
                StaleRunnerBubble(updating: store.restartingRunners.contains(sessionId)) {
                    AppHaptics.confirm()
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
        .onDisappear {
            if talking { stopTalking(cancelled: true) } else { dictation.stop() }
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
        .modifier(AttachmentSources(showPhotos: $showPhotos, showFiles: $showFiles, showCamera: $showCamera,
                                    showCameraPermission: $showCameraPermission) { add($0) })
        .alert("Goal", isPresented: Binding(get: { goalDraft != nil }, set: { if !$0 { goalDraft = nil } })) {
            TextField("What should the agent keep working toward?", text: Binding(get: { goalDraft ?? "" }, set: { goalDraft = $0 }), axis: .vertical)
            Button("Set Goal") {
                let objective = (goalDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                goalDraft = nil
                guard !objective.isEmpty else { return }
                AppHaptics.confirm()
                Task { await store.setGoal(sessionId, objective: objective) }
            }
            Button("Cancel", role: .cancel) { goalDraft = nil }
        } message: {
            Text("The agent keeps pursuing it across turns until it's done.")
        }
        .onChange(of: dictation.error) { _, error in
            if let error {
                AppHaptics.error()
                store.lastError = error
            }
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
                // Push to talk takes over this part of the row (WhatsApp): the trash, "Slide to
                // cancel" and the moving bars in place of these controls, which hide meanwhile.
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
                        AttachmentSources.openCamera(show: $showCamera, denied: $showCameraPermission)
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
                }
                .opacity(talking ? 0 : 1)
                .allowsHitTesting(!talking)
                .accessibilityHidden(talking)
                // Where the trash will be: the panel lays it out from this edge.
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX + TalkPanel.trashCenter } action: { trashX = $0 }
                .overlay {
                    if talking {
                        TalkPanel(levels: dictation.levels, cancelArmed: talkCancelArmed)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                if !canSend || dictation.isRecording || talking {
                    // Tap: dictate into the field. Hold: push to talk, sent when released, and the
                    // agent's answer is read aloud (a spoken conversation).
                    PushToTalkButton(recording: dictation.isRecording, talking: talking, cancelArmed: $talkCancelArmed,
                                     trashOffset: trashX.flatMap { trash in micX.map { trash - $0 } }) {
                        if dictation.isRecording {
                            dictation.stop()
                            AppHaptics.light()
                        } else {
                            AppHaptics.light()
                            dictation.toggle(prefix: text) { text = $0 }
                        }
                    } onHoldStart: {
                        startTalking()
                    } onHoldEnd: { cancelled in
                        stopTalking(cancelled: cancelled)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { micX = $0 }
                }
                // Kept in place, unseen, while talking so the mic doesn't slide out from under the finger.
                sendButton
                    .opacity(talking ? 0 : 1)
                    .allowsHitTesting(!talking)
                    .accessibilityHidden(talking)
            }
            .animation(.smooth(duration: 0.2), value: talking)
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    /// The side the pill sits on: the one just dropped on (until the account setting has it), else the setting.
    private var statusOnRight: Bool { (droppedSide ?? store.accountSettings?.statusPosition) == .right }

    /// Press and hold the status line (0.3 s), then drag it sideways; released, it springs to the
    /// side its projected position falls on and that becomes the account's Status Position.
    /// Holding first keeps the drag from fighting the conversation's scroll and the text field.
    private var statusDrag: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !statusGrabbed {
                    statusGrabbed = true
                    AppHaptics.light()
                }
                statusDragX = drag?.translation.width ?? 0
            }
            .onEnded { value in
                defer { statusGrabbed = false }
                guard case .second(true, let drag?) = value else {
                    statusDragX = 0
                    return
                }
                let start = statusOnRight ? statusRowWidth - statusPillWidth / 2 - 4 : statusPillWidth / 2 + 4
                let side = StatusSideSnap.side(center: start + drag.translation.width, velocity: drag.velocity.width,
                                               width: statusRowWidth)
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.72)) {
                    droppedSide = side
                    statusDragX = 0
                }
                AppHaptics.light()
                if side != store.accountSettings?.statusPosition {
                    Task { await store.updateAccountSettings { $0.delta(statusPosition: side) } }
                }
            }
    }

    /// The status pill, and beside it what runs in the background.
    private func statusRow(_ session: Session) -> some View {
        // The daemon's count already includes active delegated runs; without it, add them up here.
        let running = session.reportsBackgroundActivity
            ? session.backgroundActivityCount
            : (store.transcripts[sessionId]?.subagents.filter { $0.status == .running }.count ?? 0)
                + (store.delegatedRuns[sessionId]?.filter(\.isActive).count ?? 0)
        return HStack(spacing: 6) {
            SessionStatusRow(session: session, agent: session.agentIdentity)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text(session.agentIdentity == nil ? "Shows the session's details" : "Shows the agent's card"))
                .accessibilityAction { openAgentCard() }
                // A sheet on the iPhone; on iPad and Mac a popover beside the pill.
                .popover(isPresented: $showAgentCard, arrowEdge: .top) {
                    AgentCardView(sessionId: sessionId)
                        .presentationCompactAdaptation(.sheet)
                        .presentationDragIndicator(.visible)
                }
            ResumeSessionButton(sessionId: sessionId)
                .font(.caption.weight(.semibold))
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
            if running > 0 {
                BackgroundActivityPill(count: running) {
                    Self.log.notice("background pill tapped (\(running, privacy: .public) running)")
                    AppHaptics.light()
                    onShowActivity()
                }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { statusPillWidth = $0 }
        .scaleEffect(statusGrabbed ? 1.04 : 1)
        .offset(x: statusDragX)
        // A plain tap opens the card; held 0.3 s, the pill drags instead.
        .gesture(statusDrag.exclusively(before: TapGesture().onEnded { openAgentCard() }))
        .animation(.smooth(duration: 0.15), value: statusGrabbed)
        // Left (as "Online" always was) or right above the mic, as the account's settings say.
        .padding(statusOnRight ? .trailing : .leading, 4)
        .frame(maxWidth: .infinity, alignment: statusOnRight ? .trailing : .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { statusRowWidth = $0 }
        .onChange(of: store.accountSettings?.statusPosition) { _, saved in
            if saved == droppedSide { droppedSide = nil }
        }
        .animation(.smooth(duration: 0.25), value: running > 0)
    }

    private func openAgentCard() {
        AppHaptics.light()
        showAgentCard = true
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
            AppHaptics.light()
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
                        // One bar per level the model offers, filled up to it (all with Ultracode).
                        if let bars = EffortBars(level: effort, levels: controls.effortModel?.effortLevels ?? [],
                                                 ultracode: controls.ultracode == true) {
                            EffortBarsMark(bars: bars)
                                .accessibilityLabel(Text(controls.ultracode == true ? "Effort Ultracode" : "Effort \(EffortSlider.name(effort))"))
                        }
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
        .glassHover()
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
            PermissionSymbol(mode: controls.permissionMode, agentId: controls.agentId)
        }
        .buttonStyle(.glass)
        .glassHover()
        .buttonBorderShape(.circle)
        .fixedSize()
        .help(Text(label))
        .accessibilityLabel("Permission mode")
        .accessibilityValue(Text(label))
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
                    .buttonStyle(.pressable)
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
            if stop {
                AppHaptics.warning()
                onStop()
            } else {
                send()
            }
        } label: {
            Image(systemName: stop ? "stop.fill" : "arrow.up")
                .font(.body.weight(.bold))
                .frame(width: 22, height: 22)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glassProminent)
        .glassHover()
        .buttonBorderShape(.circle)
        .tint(stop ? .red : .userBubble)
        .disabled(!stop && !canSend)
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
struct SessionStatusRow: View {
    let session: Session
    /// Who works in the session: its name leads, and the state follows it.
    var agent: AgentIdentity?

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
                if let agent {
                    // "Mateo", then what isn't plain from the mark ("· needs your approval").
                    Text(verbatim: agent.name)
                        .foregroundStyle(look.tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    if look.icon != nil || look.tint == nil {
                        Text("· \(Text(look.text))").foregroundStyle(.secondary)
                    }
                } else {
                    Text(look.text)
                        .foregroundStyle(look.tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    if let detail = look.detail {
                        detail.foregroundStyle(.secondary)
                    }
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
        case .actionRequired: return Look(text: "Waiting for your answer", icon: "hand.raised.fill", tint: .orange)
        case .failed: return Look(text: "Turn failed", icon: "exclamationmark.triangle.fill", tint: .red)
        case .idle: return Look(text: "Online", tint: .green)
        case .offline:
            return Look(text: "Inactive", detail: session.activeAt.map { Text("· active \($0, format: .relative(presentation: .named))") })
        }
    }
}

/// Effort as rising bars, drawn so there can be as many as the model has levels (the
/// `cellularbars` symbol only has 4). Monochrome like it: filled bars solid, the rest faint.
struct EffortBarsMark: View {
    let bars: EffortBars
    @ScaledMetric(relativeTo: .subheadline) private var height = 11

    var body: some View {
        HStack(alignment: .bottom, spacing: max(1, height * 0.12)) {
            ForEach(0..<bars.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: height * 0.1, style: .continuous)
                    .frame(width: max(2, height * 0.2), height: height * CGFloat(index + 1) / CGFloat(bars.count))
                    .opacity(index < bars.filled ? 1 : 0.25)
            }
        }
        .frame(height: height, alignment: .bottom)
        .foregroundStyle(.secondary)
    }
}

/// The permission mode as one symbol, everywhere it's shown (composer, menus, task detail, agent
/// card): one family, the circled outline of each, same weight and scale, monochrome in the text
/// color. No mode is colored: having every permission is the normal case, not an alert.
struct PermissionSymbol: View {
    let mode: PermissionMode
    /// The provider, which decides what `default` means (`PermissionMode.symbolName`).
    let agentId: String?
    var textStyle: Font.TextStyle = .body
    var side: CGFloat = 22

    var body: some View {
        Image(systemName: mode.symbolName(agentId: agentId))
            .font(.system(textStyle, weight: .regular))
            .imageScale(.medium)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
            .frame(width: side, height: side)
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
                .glassHover()
                .buttonBorderShape(.circle)
                .tint(.userBubble)
        } else {
            Button(action: action) { icon }
                .buttonStyle(.glass)
                .glassHover()
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

struct FileSuggestions: View {
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
                        AppHaptics.selection()
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
                    .buttonStyle(.pressable)
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
                    AppHaptics.selection()
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
                .buttonStyle(.pressable)
            }
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// The ⊕ menu: paste, camera, photos and files, mentions, and the goal. Compared by its displayed
/// options so unrelated session updates don't rebuild the menu while it is open.
struct AddMenu: View, Equatable {
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
            // Pointing the agent first, then what to attach; the camera last (used least).
            if canMention {
                Button { AppHaptics.light(); onMention() } label: {
                    Label {
                        Text("Mention a File")
                        Text("Point the agent at a file of the project")
                    } icon: {
                        Image(systemName: "at")
                    }
                }
            }
            if canSetGoal {
                Button { AppHaptics.light(); onGoal() } label: {
                    Label {
                        Text("Goal")
                        Text("Set a goal to keep pursuing")
                    } icon: {
                        Image(systemName: "scope")
                    }
                }
            }
            if canMention || canSetGoal { Divider() }
            Button("File", systemImage: "doc") { AppHaptics.light(); onFiles() }
            Button("Photo or Video", systemImage: "photo.on.rectangle") { AppHaptics.light(); onPhotos() }
            Button("Paste", systemImage: "doc.on.clipboard") { AppHaptics.light(); onPaste() }
            #if os(iOS)
            if CameraPicker.isAvailable {
                Button("Take Photo", systemImage: "camera") { AppHaptics.light(); onCamera() }
            }
            #endif
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: 22, height: 22)
        }
        // The same glass disc as the mic and send buttons beside it, on every platform.
        .menuStyle(.button)
        .menuIndicator(.hidden)
        // The same order whichever way the menu opens (up from the iPhone composer, down on the Mac).
        .menuOrder(.fixed)
        .buttonStyle(.glass)
        .glassHover()
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
                    Label { Text(mode.label(agentId: agentId)) } icon: { Image(systemName: mode.symbolName(agentId: agentId)) }
                        .tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            PermissionSymbol(mode: mode, agentId: agentId)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .glassHover()
        .buttonBorderShape(.circle)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Permission mode")
        .accessibilityValue(Text(label))
        .accessibilityIdentifier("composer-permission")
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
                        if nearest != index { AppHaptics.selection() }
                        if nearest != dragIndex {
                            withAnimation(.snappy(duration: 0.18)) { dragIndex = nearest }
                        }
                    }
                    .onEnded { _ in
                        if let dragIndex, levels[dragIndex] != selection { onCommit(levels[dragIndex]) }
                        dragIndex = nil
                    })
                .animation(.snappy(duration: 0.2), value: index)
            }
            .frame(height: knob + inset * 2)
            .accessibilityElement()
            .accessibilityLabel("Effort")
            .accessibilityValue(Self.name(levels[index]))
            .accessibilityAdjustableAction { direction in
                let next = direction == .increment ? min(index + 1, levels.count - 1) : max(index - 1, 0)
                if next != index {
                    AppHaptics.selection()
                    onCommit(levels[next])
                }
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
        .glassHover()
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
        .buttonStyle(.pressable)
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

/// The composer's mic: a tap dictates into the field (tap again to stop); held down, it's push to
/// talk — it listens while held, then hands the result to the composer, or cancels on the trash.
struct PushToTalkButton: View {
    let recording: Bool
    let talking: Bool
    @Binding var cancelArmed: Bool
    /// From the mic to the trash along the row (negative: the trash is on the left); nil until
    /// the panel is laid out.
    var trashOffset: CGFloat?
    var holdHint: LocalizedStringKey = "Hold to talk; release to send"
    let onTap: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: (_ cancelled: Bool) -> Void
    /// Where the trash is when the panel hasn't reported it.
    static let cancelDistance: CGFloat = 110
    /// The red zone: the share of the way nearest the trash. Once the finger is in it, the
    /// magnet catches the mic onto the trash; the other 60% is the safe, green side…
    static let magnetShare: CGFloat = 0.4
    /// …and the magnet lets go once the finger is back at half the way.
    static let releaseShare: CGFloat = 0.5
    /// How big the held mic grows, so it shows around the thumb.
    static let heldScale: CGFloat = 1.9
    @State private var pressing = false
    @State private var held = false
    @State private var holdTimer: Task<Void, Never>?
    /// Where the held mic sits: under the finger, or stuck to the trash.
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        // The mic stays a mic: the thumb covers it, and the panel shows that it listens.
        Image(systemName: cancelArmed && talking ? "trash" : talking || recording ? "mic.fill" : "mic")
            .font(.body.weight(.semibold))
            .frame(width: 22, height: 22)
            .foregroundStyle(talking || recording ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .contentTransition(.symbolEffect(.replace))
            .padding(9)
            .background {
                if talking {
                    // The app's blue while it listens; red once stuck to the trash.
                    Circle().fill(cancelArmed ? Color.red : Color.userBubble)
                } else if recording {
                    Circle().fill(Color.userBubble)
                }
            }
            .glassEffect(.regular.interactive(), in: Circle())
            // Bigger while held, so it shows around the thumb, and it follows the finger.
            .scaleEffect(talking ? Self.heldScale : pressing ? 0.9 : 1)
            .offset(talking ? dragOffset : .zero)
            .animation(.smooth(duration: 0.15), value: talking)
            .animation(.smooth(duration: 0.1), value: pressing)
            .contentShape(Circle())
            #if os(iOS)
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.lift)
            #endif
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !pressing {
                        pressing = true
                        AppHaptics.light()
                        holdTimer = Task {
                            try? await Task.sleep(for: .milliseconds(200))
                            guard !Task.isCancelled, pressing else { return }
                            held = true
                            onHoldStart()
                        }
                    }
                    guard held else { return }
                    follow(value.translation)
                }
                .onEnded { _ in
                    holdTimer?.cancel()
                    pressing = false
                    if held {
                        held = false
                        // Stuck to the trash it's deleted, wherever the finger is; otherwise sent.
                        onHoldEnd(cancelArmed)
                        withAnimation(.spring(duration: 0.3)) { dragOffset = .zero }
                    } else {
                        onTap()
                    }
                })
            .accessibilityLabel(recording ? "Stop dictation" : "Dictate")
            .accessibilityHint(holdHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
    }

    /// Under the finger, wherever it goes, until the finger is in the red zone near the trash:
    /// then the magnet catches it there.
    private func follow(_ finger: CGSize) {
        // A measured trash closer than the mic itself is a layout still settling.
        let trash = trashOffset.flatMap { $0 < -60 ? $0 : nil } ?? -Self.cancelDistance
        let fromTrash = hypot(finger.width - trash, finger.height)
        let stuck = fromTrash < abs(trash) * (cancelArmed ? Self.releaseShare : Self.magnetShare)
        // Not too far from the composer: above the field at most, a little below the row.
        let free = CGSize(width: min(max(finger.width, trash), 40), height: min(max(finger.height, -260), 80))
        if stuck != cancelArmed {
            cancelArmed = stuck
            // A firmer tap when it sticks, like a magnet catching.
            if stuck { AppHaptics.confirm() } else { AppHaptics.light() }
            withAnimation(.spring(duration: 0.25, bounce: 0.3)) { dragOffset = stuck ? CGSize(width: trash, height: 0) : free }
        } else if !stuck {
            dragOffset = free
        }
    }
}

/// Push to talk's panel in the composer's row, in place of its controls (the words heard show in
/// the field above): the trash with "Slide to cancel" beside it on the left, where the finger
/// doesn't cover them, and bars moving with the voice next to the mic. No glass of its own: the
/// composer's is enough, and a second layer let the hidden controls show through.
struct TalkPanel: View {
    let levels: [Float]
    let cancelArmed: Bool
    /// From the row's leading edge to the trash's center, where the held mic sticks.
    static let trashCenter: CGFloat = 16

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: cancelArmed ? "trash.fill" : "trash")
                .font(.body.weight(.semibold))
                .foregroundStyle(cancelArmed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .scaleEffect(cancelArmed ? 1.25 : 1)
                .animation(.smooth(duration: 0.15), value: cancelArmed)
            Text(cancelArmed ? "Release to cancel" : "‹ Slide to cancel")
                .font(.subheadline.weight(cancelArmed ? .semibold : .regular))
                .foregroundStyle(cancelArmed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.suffix(16).enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(cancelArmed ? Color.secondary : Color.green)
                        .frame(width: 3, height: 4 + CGFloat(level) * 18)
                }
            }
            .frame(width: 62, height: 24, alignment: .trailing)
            .animation(.linear(duration: 0.05), value: levels.count)
        }
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
