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
                                MachineRow(machine: machine, online: machine.isOnline(at: context.date))
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
        .refreshable { await store.refreshMachines() }
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
                content(machine, online: machine.isOnline(at: context.date))
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
            Text(online ? message : String(localized: "The machine is offline.")).foregroundStyle(.secondary)
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
        guard machine?.isOnline() == true else {
            tools = .failed(String(localized: "The machine is offline."))
            return
        }
        tools = .loading
        do {
            tools = try await store.detectTools(on: machineId, refresh: refresh).map(ToolsState.loaded) ?? .unsupported
        } catch {
            tools = .failed(UserFacingError.message(for: error))
        }
    }
}
