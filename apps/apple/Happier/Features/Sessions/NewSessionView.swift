import HappierKit
import SwiftUI

/// Start an agent in a folder on one of your machines (the daemon's `spawn-happy-session`).
struct NewSessionView: View {
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var machineId: String?
    @State private var directory = ""
    @State private var agentId = "claude"
    @State private var permissionMode: PermissionMode = .default
    @State private var firstMessage = ""
    @State private var starting = false
    @State private var error: String?
    @State private var folderToApprove: String?
    @FocusState private var messageFocused: Bool

    private var machine: Machine? { store.machines.first { $0.id == machineId } }

    private var recentDirectories: [String] {
        machineId.map { Machine.recentDirectories(machineId: $0, sessions: Array(store.sessions.values)) } ?? []
    }

    /// Agents you already use (most used first), then the common built-ins.
    private var agents: [String] {
        var counts: [String: Int] = [:]
        for session in store.sessions.values { if let id = session.agentId { counts[id, default: 0] += 1 } }
        let used = counts.sorted { $0.value > $1.value }.map(\.key)
        var seen = Set<String>()
        return (used + ["claude", "codex", "gemini", "opencode"]).filter { $0 != "customAcp" && seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Machine") {
                    if store.machines.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Loading machines…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(store.machines) { item in
                        choiceRow(selected: item.id == machineId) {
                            machineId = item.id
                            directory = Machine.recentDirectories(machineId: item.id, sessions: Array(store.sessions.values)).first ?? item.homeDir ?? ""
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(item.active ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    Text(item.active ? "Online" : "Offline").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    TextField("Folder path", text: $directory)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    ForEach(recentDirectories.prefix(6), id: \.self) { path in
                        choiceRow(selected: path == directory) { directory = path } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((path as NSString).lastPathComponent)
                                Text(displayPath(path)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                } header: {
                    Text("Folder")
                }

                Section("Agent") {
                    Picker("Agent", selection: $agentId) {
                        ForEach(agents, id: \.self) { id in
                            Text(Agent.displayNames[id] ?? id).tag(id)
                        }
                    }
                    Picker("Permissions", selection: $permissionMode) {
                        ForEach(PermissionMode.allCases, id: \.self) { mode in
                            Text(mode.label(agentId: agentId)).tag(mode)
                        }
                    }
                }

                Section("First Message") {
                    TextField("What should the agent work on? (optional)", text: $firstMessage, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($messageFocused)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView()
                    } else {
                        Button("Start") { start(approve: false) }
                            .disabled(machineId == nil || directory.trimmingCharacters(in: .whitespaces).isEmpty || machine?.active != true)
                    }
                }
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
                if let used = agents.first { agentId = used }
            }
            .interactiveDismissDisabled(starting)
        }
    }

    private func start(approve: Bool) {
        guard let machineId else { return }
        starting = true
        error = nil
        let path = directory.trimmingCharacters(in: .whitespaces)
        Task {
            let outcome = await store.createSession(machineId: machineId, directory: path, agentId: agentId,
                                                    permissionMode: permissionMode, firstMessage: firstMessage, approveNewDirectory: approve)
            starting = false
            switch outcome {
            case .created: dismiss()
            case .needsDirectoryApproval(let folder): folderToApprove = folder
            case .failed(let message): error = message
            }
        }
    }

    private func displayPath(_ path: String) -> String {
        if let home = machine?.homeDir, path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func choiceRow(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) {
            HStack {
                label()
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.userBubble).fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
