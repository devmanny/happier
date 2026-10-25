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
    @Environment(HappierStore.self) private var store
    @State private var machineId: String?
    @State private var directory = ""
    @State private var agentId = "claude"
    @State private var modelId = "default"
    @State private var effort: String?
    @State private var permissionMode: PermissionMode = .yolo
    /// The agent last started from here; its model and effort are remembered per agent.
    @AppStorage("happier.newSession.agent") private var lastAgentId = ""
    @State private var firstMessage = ""
    @State private var starting = false
    @State private var error: String?
    @State private var folderToApprove: String?
    @State private var showBrowser = false
    @State private var showModelPicker = false
    @State private var dictation = Dictation()
    @FocusState private var messageFocused: Bool

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
            Spacer(minLength: 24)
            // An empty conversation, as in ChatGPT and Claude: what you start is written below.
            VStack(spacing: 12) {
                // The agent's logo is also its picker: the same choices as the pill in the composer.
                Button { showModelPicker = true } label: {
                    AgentAvatar(agentId: agentId, size: 64, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Agent"))
                Text("What should we work on?")
                    .font(.title2.weight(.semibold))
                Text(placeLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 24)
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
            composer
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("New Session")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: agentId, initial: true) { _, agent in restoreChoices(for: agent) }
        .onChange(of: modelId) { _, _ in fitEffort() }
        .onChange(of: dictation.error) { _, error in
            if let error { store.lastError = error }
        }
        .alert("Create Folder?", isPresented: Binding(get: { folderToApprove != nil }, set: { if !$0 { folderToApprove = nil } })) {
            Button("Create and Start") { start(approve: true) }
            Button("Cancel", role: .cancel) {}
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

    private var canStart: Bool {
        !starting && machineId != nil && machine?.active == true
            && !directory.trimmingCharacters(in: .whitespaces).isEmpty
            && !firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The message and, as pills under it, where and with what it starts: agent and model first.
    /// The same card as a live conversation's composer (`Composer.card`).
    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Describe a task or ask a question…", text: $firstMessage, axis: .vertical)
                .lineLimit(1...8)
                .focused($messageFocused)
                .textFieldStyle(.plain)
                .onSubmit { if canStart { start(approve: false) } }
                .padding(.horizontal, 6)
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        agentMenu
                        permissionMenu
                    }
                }
                .scrollClipDisabled()
                // The mic while there is nothing to send, as in a live conversation's composer.
                if firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dictation.isRecording {
                    CircleButton(systemImage: dictation.isRecording ? "waveform" : "mic", active: dictation.isRecording) {
                        dictation.toggle(prefix: firstMessage) { firstMessage = $0 }
                    }
                    .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                    .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
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
                .buttonBorderShape(.circle)
                .tint(.userBubble)
                .disabled(!canStart)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    /// Agent, model and effort: opens the same picker as a live session's model pill.
    private var agentMenu: some View {
        Button { showModelPicker = true } label: {
            chip {
                Image("Agents/\(agentId)").resizable().scaledToFit().frame(width: 15, height: 15)
                Text(agentLabel).lineLimit(1)
            }
        }
        .buttonStyle(.glass)
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
                Button { permissionMode = mode } label: { checked(mode.label(agentId: agentId), mode == permissionMode) }
            }
        } label: {
            chip { Text(permissionMode.label(agentId: agentId)) }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Permission mode")
    }

    private var machineMenu: some View {
        Menu {
            ForEach(store.machines) { item in
                Button {
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
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var folderMenu: some View {
        Menu {
            ForEach(recentDirectories.prefix(8), id: \.self) { path in
                Button { directory = path } label: { checked(displayPath(path), path == directory) }
            }
            Divider()
            Button("Browse Folders…", systemImage: "folder.badge.gearshape") { showBrowser = true }
                .disabled(machine?.active != true)
        } label: {
            chip {
                Image(systemName: "folder")
                Text(directory.isEmpty ? String(localized: "Folder") : (directory as NSString).lastPathComponent).lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
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
        starting = true
        error = nil
        let path = directory.trimmingCharacters(in: .whitespaces)
        rememberChoices()
        let effort = effortLevels.isEmpty ? nil : effort
        Task {
            let outcome = await store.createSession(machineId: machineId, directory: path, agentId: agentId, permissionMode: permissionMode,
                                                    modelId: modelId, effort: effort, firstMessage: firstMessage, approveNewDirectory: approve)
            starting = false
            switch outcome {
            case .created: firstMessage = ""
            case .needsDirectoryApproval(let folder): folderToApprove = folder
            case .failed(let message): error = message
            }
        }
    }

    // MARK: Remembered model and effort

    private static func modelKey(_ agent: String) -> String { "happier.newSession.model.\(agent)" }
    private static func effortKey(_ agent: String) -> String { "happier.newSession.effort.\(agent)" }

    /// The model and effort last started with this agent, while it still offers them.
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
