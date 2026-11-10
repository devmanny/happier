import HappierKit
import SwiftUI

/// "New Room": a title, how the agents call you, and the agents invited, each with the machine and
/// folder it works from. Whether another agent's mention wakes it is per member: on for most, off
/// for Claude until you allow it past the Consumer Terms warning (automated access, section 3.7).
struct NewRoomSheet: View {
    /// The room once stored, to open it.
    let created: (AgentRoom) -> Void
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var userName = ""
    @State private var invited: [String: Invite] = [:]
    @State private var saving = false
    /// The member whose "Answers other agents" waits for the warning to be answered.
    @State private var warning: String?

    struct Invite: Equatable {
        var machineId: String
        var directory: String
        var wakeByAgents: Bool
    }

    private var agents: [AgentProfile] {
        AgentRoster.ordered(store.agentProfiles, by: store.accountSettings?.agentOrder ?? [])
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !invited.isEmpty
            && invited.values.allSatisfy { !$0.machineId.isEmpty && !$0.directory.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Your name (how the agents mention you)", text: $userName)
                        .textContentType(.name)
                }
                Section {
                    ForEach(agents) { agent in
                        member(agent)
                    }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Each agent works from its own folder and answers when it is mentioned with @. Another agent's mention only wakes the agents that answer other agents.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Room")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(!canCreate || saving)
                        .accessibilityIdentifier("room-create")
                }
            }
            .onAppear {
                if userName.isEmpty { userName = store.activeRooms.first?.userName ?? "" }
            }
            .alert("Automated Access with Claude", isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
                Button("Allow") {
                    if let id = warning { invited[id]?.wakeByAgents = true }
                    warning = nil
                }
                Button("Cancel", role: .cancel) { warning = nil }
            } message: {
                Text("""
                When another agent mentions it, it answers without you, which is automated access. Anthropic's Consumer Terms \
                (section 3.7) ask for an API key for that, not a Claude subscription. Otherwise it waits for you to let it answer.
                """)
            }
        }
    }

    @ViewBuilder
    private func member(_ agent: AgentProfile) -> some View {
        let isIn = Binding(get: { invited[agent.id] != nil }, set: { on in
            invited[agent.id] = on ? defaultInvite(agent) : nil
        })
        Toggle(isOn: isIn) {
            Label {
                Text(agent.name)
            } icon: {
                AgentAvatar(agentId: agent.providerId, size: 26, emoji: agent.emoji)
            }
        }
        .accessibilityIdentifier("room-invite-\(agent.id)")
        if let invite = invited[agent.id] {
            Picker("Machine", selection: Binding(get: { invite.machineId }, set: { machine in
                invited[agent.id]?.machineId = machine
                invited[agent.id]?.directory = recentDirectory(machine) ?? ""
            })) {
                ForEach(store.machines) { Text($0.name).tag($0.id) }
            }
            .padding(.leading, 34)
            TextField("Folder", text: Binding(get: { invite.directory }, set: { invited[agent.id]?.directory = $0 }))
                .padding(.leading, 34)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Toggle("Answers other agents", isOn: Binding(get: { invite.wakeByAgents }, set: { on in
                if on, TaskRecurrence.needsAutomatedAccessWarning(providerId: agent.providerId) {
                    warning = agent.id
                } else {
                    invited[agent.id]?.wakeByAgents = on
                }
            }))
            .padding(.leading, 34)
        }
    }

    private func defaultInvite(_ agent: AgentProfile) -> Invite {
        let machine = store.machines.first { $0.active } ?? store.machines.first
        return Invite(machineId: machine?.id ?? "", directory: machine.flatMap { recentDirectory($0.id) } ?? "",
                      wakeByAgents: AgentRoom.Member.answersAgentsByDefault(providerId: agent.providerId))
    }

    private func recentDirectory(_ machineId: String) -> String? {
        Machine.recentDirectories(machineId: machineId, sessions: Array(store.sessions.values)).first
            ?? store.machines.first { $0.id == machineId }?.homeDir
    }

    private func create() {
        let members = agents.compactMap { agent -> AgentRoom.Member? in
            guard let invite = invited[agent.id] else { return nil }
            return AgentRoom.Member(agent, machineId: invite.machineId,
                                    directory: invite.directory.trimmingCharacters(in: .whitespaces), wakeByAgents: invite.wakeByAgents)
        }
        let name = userName.trimmingCharacters(in: .whitespaces)
        let room = AgentRoom(title: title.trimmingCharacters(in: .whitespaces), userName: name.isEmpty ? nil : name, members: members)
        saving = true
        Task {
            let saved = await store.createRoom(room)
            saving = false
            guard let saved else { return }
            AppHaptics.success()
            dismiss()
            created(saved)
        }
    }
}
