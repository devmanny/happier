import HappierKit
import SwiftUI

/// The account's machines, online first (`settings/machines.tsx`). Revoked and replaced ones are
/// not listed.
struct MachinesView: View {
    @Environment(HappierStore.self) private var store

    var body: some View {
        // Re-evaluated every half minute: "online" means a heartbeat within the last minute.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Form {
                if store.machines.isEmpty {
                    ContentUnavailableView("No Machines Yet", systemImage: "desktopcomputer",
                                           description: Text("Run happier on a computer and sign in with this account; it shows up here."))
                } else {
                    Section {
                        ForEach(store.machines) { machine in
                            NavigationLink {
                                MachineDetailView(machineId: machine.id)
                            } label: {
                                MachineRow(machine: machine, online: machine.isOnline(at: store.presenceDate(context.date)))
                            }
                        }
                    } footer: {
                        Text("To add one, install the Happier CLI on it and run happier.")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Machines")
        .refreshable { await store.refreshMachines(reportErrors: true) }
        .task { await store.refreshMachines() }
    }
}

private struct MachineRow: View {
    let machine: Machine
    let online: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: machine.platform == "darwin" ? "laptopcomputer" : "desktopcomputer")
                .font(.title3)
                .foregroundStyle(online ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = []
        if machine.displayName != nil, let host = machine.host { parts.append(host) }
        parts.append(online ? String(localized: "Online") : String(localized: "Offline"))
        if let version = machine.cliVersion { parts.append("CLI \(version)") }
        return parts.joined(separator: " · ")
    }
}

/// One machine (`machine/[id]/index.tsx`): what it is, its daemon, the agents it has, and
/// renaming, stopping the daemon and removing it from the account.
private struct MachineDetailView: View {
    let machineId: String
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: String?
    @State private var confirmingStop = false
    @State private var confirmingRemove = false
    @State private var working = false
    @State private var tools: ToolsState = .loading

    enum ToolsState {
        case loading, loaded(DetectedTools), unsupported, failed(String)
    }

    private var machine: Machine? { store.machines.first { $0.id == machineId } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let machine {
                content(machine, online: machine.isOnline(at: store.presenceDate(context.date)))
            } else {
                ContentUnavailableView("Machine Not Found", systemImage: "desktopcomputer",
                                       description: Text("It may have been removed from your account."))
            }
        }
        .navigationTitle(machine?.name ?? String(localized: "Machine"))
        .toolbar {
            if machine != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Rename…", systemImage: "pencil") {
                        AppHaptics.light()
                        renaming = machine?.displayName ?? ""
                    }
                }
            }
        }
        .alert("Rename Machine", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(machine?.host ?? String(localized: "Name"), text: Binding(get: { renaming ?? "" }, set: { renaming = $0 }))
            Button("Rename") {
                let name = renaming ?? ""
                AppHaptics.confirm()
                Task { await store.renameMachine(machineId, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to use the computer's own name.")
        }
        .confirmationDialog("Stop the daemon?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop Daemon", role: .destructive) {
                AppHaptics.warning()
                working = true
                Task {
                    _ = await store.stopDaemon(machineId)
                    working = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running sessions stay alive, but new ones can't start on this machine until you start Happier on it again.")
        }
        .confirmationDialog("Remove this machine?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove Machine", role: .destructive) {
                AppHaptics.warning()
                working = true
                Task {
                    if await store.revokeMachine(machineId) { dismiss() }
                    working = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its access to your account is revoked, with its access keys and automations. To use it again, sign in from its CLI.")
        }
        .task { await loadTools(refresh: false) }
    }

    private func content(_ machine: Machine, online: Bool) -> some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(online ? Color.green : Color.secondary).frame(width: 8, height: 8)
                        Text(online ? "Online" : "Offline")
                    }
                }
                if let host = machine.host { LabeledContent("Host", value: host) }
                if let platform = machine.platform { LabeledContent("Platform", value: platform) }
                if let home = machine.homeDir { LabeledContent("Home Folder", value: home) }
                if let version = machine.cliVersion { LabeledContent("CLI Version", value: version) }
                LabeledContent("Last Seen") {
                    if let seen = machine.activeAt { Text(seen, format: .relative(presentation: .named)) } else { Text("Never") }
                }
                LabeledContent("Machine ID") {
                    Text(machine.id).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }

            Section {
                LabeledContent("Daemon") {
                    Text(daemonStatus(machine, online: online))
                }
                if let daemon = machine.daemon {
                    if let pid = daemon.pid { LabeledContent("Process ID", value: String(pid)) }
                    if let port = daemon.httpPort { LabeledContent("Port", value: String(port)) }
                    if let started = daemon.startedAt {
                        LabeledContent("Started") { Text(started, format: .relative(presentation: .named)) }
                    }
                    if let version = daemon.cliVersion { LabeledContent("Started with CLI", value: version) }
                }
                Button("Stop Daemon…", systemImage: "stop.circle", role: .destructive) {
                    AppHaptics.light()
                    confirmingStop = true
                }
                .disabled(!online || working || machine.daemon?.isShuttingDown == true)
            } header: {
                Text("Daemon")
            }

            ConversationSearchSection(machineId: machine.id, machineName: machine.name, online: online)

            Section {
                toolsContent(online: online)
            } header: {
                HStack {
                    Text("Agents on This Machine")
                    Spacer()
                    Button("Check Again", systemImage: "arrow.clockwise") {
                        AppHaptics.light()
                        Task { await loadTools(refresh: true) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!online)
                }
            }

            Section {
                Button("Remove Machine…", systemImage: "trash", role: .destructive) {
                    AppHaptics.light()
                    confirmingRemove = true
                }
                .disabled(working)
            } footer: {
                Text("Revokes this machine and removes it from your account.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func toolsContent(online: Bool) -> some View {
        switch tools {
        case .loading:
            HStack {
                Text("Checking…").foregroundStyle(.secondary)
                Spacer()
                HappierSpinner(size: HappierSpinner.mini)
            }
        case .unsupported:
            Text("Update Happier on this machine to see its agents.").foregroundStyle(.secondary)
        case .failed(let message):
            Text(online || !store.reachesRelay ? message : String(localized: "The machine is offline.")).foregroundStyle(.secondary)
        case .loaded(let detected):
            ForEach(detected.agents) { cli in
                toolRow(Agent.displayNames[cli.id] ?? cli.id, agentId: cli.id, state: cli.state)
            }
            if let tmux = detected.tmux { toolRow("tmux", agentId: nil, state: tmux) }
        }
    }

    private func toolRow(_ name: String, agentId: String?, state: DetectedTools.State) -> some View {
        HStack(spacing: 10) {
            if let agentId { AgentAvatar(agentId: agentId, size: 22) } else { Image(systemName: "terminal").frame(width: 22) }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                if case .installed(_, let path?) = state {
                    Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            switch state {
            case .installed(let version, _):
                Text(version ?? String(localized: "Installed")).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .missing:
                Text("Not Installed").font(.caption).foregroundStyle(.secondary)
            case .unknown:
                Text("Unknown").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func daemonStatus(_ machine: Machine, online: Bool) -> String {
        if machine.daemon?.isShuttingDown == true { return String(localized: "Stopping") }
        return online ? String(localized: "Running") : String(localized: "Not Reachable")
    }

    private func loadTools(refresh: Bool) async {
        // Cut off from the relay, it's this device that can't ask, not the machine that's offline.
        guard store.reachesRelay else {
            tools = .failed(store.notConnectedMessage)
            return
        }
        guard machine?.isOnline(at: store.presenceDate()) == true else {
            tools = .failed(String(localized: "The machine is offline."))
            return
        }
        tools = .loading
        do {
            tools = try await store.detectTools(on: machineId, refresh: refresh).map(ToolsState.loaded) ?? .unsupported
        } catch {
            tools = .failed(UserFacingError.message(for: error, hasNetworkPath: store.hasNetworkPath))
        }
    }
}

/// Conversation search on this machine: whether its daemon keeps the full-text index of the
/// account's conversations and answers searches, how far it has read, and the index's size.
/// Turning it off offers to delete the index too.
private struct ConversationSearchSection: View {
    let machineId: String
    let machineName: String
    let online: Bool
    @Environment(HappierStore.self) private var store
    @State private var state: LoadState = .loading
    @State private var switching = false
    @State private var confirmingOff = false
    /// Bumped by each switch, so the status is followed again (a machine just turned on starts indexing).
    @State private var statusGeneration = 0

    enum LoadState: Equatable {
        case loading
        case loaded(MessageSearch.Status)
        case unsupported
        case failed(String)
    }

    var body: some View {
        Section {
            switch state {
            case .loading:
                HStack {
                    Text("Conversation Search")
                    Spacer()
                    HappierSpinner(size: HappierSpinner.mini)
                }
            case .unsupported:
                Text("Update Happier on this machine to search inside conversations.").foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
            case .loaded(let status):
                Toggle(isOn: Binding(get: { status.enabled }, set: { on in
                    AppHaptics.selection()
                    if on { Task { await apply(enabled: true, deleteIndex: false) } } else { confirmingOff = true }
                })) {
                    Text("Conversation Search")
                }
                .disabled(switching || !online)
                .accessibilityIdentifier("machine-conversation-search")
                LabeledContent("Status") { statusText(status) }
                if let coverage = status.coverage, status.state == .indexing {
                    ProgressView(value: coverage.progress)
                        .accessibilityLabel(Text("Indexing progress"))
                }
                if let bytes = status.indexBytes {
                    LabeledContent("Index Size", value: bytes.formatted(.byteCount(style: .file)))
                }
            }
        } header: {
            Text("Conversation Search")
        } footer: {
            Text("\(machineName) reads every conversation of your account once and keeps the index on its own disk, so you can search inside messages from any device. The relay never sees the text.")
        }
        .task(id: "\(online)|\(statusGeneration)") { await refreshWhileIndexing() }
        .confirmationDialog("Turn off conversation search?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Turn Off and Delete Index", role: .destructive) {
                AppHaptics.warning()
                Task { await apply(enabled: false, deleteIndex: true) }
            }
            Button("Turn Off, Keep Index") {
                AppHaptics.light()
                Task { await apply(enabled: false, deleteIndex: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(machineName) stops indexing and answering searches. Keeping the index lets it resume where it stopped; deleting it frees the disk space.")
        }
    }

    private func statusText(_ status: MessageSearch.Status) -> Text {
        switch status.state {
        case .off: Text("Off")
        case .ready: Text("Ready · \(status.coverage?.messageCount ?? 0) messages")
        case .indexing: Text("Indexing \(Int((status.coverage?.progress ?? 0) * 100)) %")
        }
    }

    private func apply(enabled: Bool, deleteIndex: Bool) async {
        switching = true
        defer { switching = false }
        if let status = await store.setMessageSearch(machineId: machineId, enabled: enabled, deleteIndex: deleteIndex) {
            state = .loaded(status)
            statusGeneration += 1
        }
    }

    /// Reads the status, again every few seconds while the machine is still indexing and this
    /// screen is open (the task ends with it).
    private func refreshWhileIndexing() async {
        guard online else {
            state = .failed(String(localized: "The machine is offline."))
            return
        }
        while !Task.isCancelled {
            do {
                if let status = try await store.messageSearchStatus(machineId: machineId) {
                    state = .loaded(status)
                    guard status.state == .indexing else { return }
                } else {
                    state = .unsupported
                    return
                }
            } catch {
                state = .failed(UserFacingError.message(for: error, hasNetworkPath: store.hasNetworkPath))
                return
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
