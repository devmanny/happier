import HappierKit
import SwiftUI

/// What the model picker edits: a provider, its model (`"default"` keeps the agent's CLI settings)
/// and, when that model has levels, the effort to run it at. `profileId` names the agent the
/// session works as on that provider; nil is the bare provider.
struct AgentModelChoice: Equatable {
    var agentId: String
    var modelId = "default"
    var effort: String?
    var profileId: String?
}

/// The one agent → model → effort picker, the same for a live conversation (iPhone sheet and Mac
/// popover) and for a new one: the machine's agents, the chosen agent's models as a checked list,
/// then the chosen model's effort when it has levels (and Ultracode where the caller offers it).
struct AgentModelPicker: View {
    let agents: [String]
    /// The live conversation's agent, tagged "Current"; nil for a new conversation.
    var currentAgentId: String?
    @Binding var choice: AgentModelChoice
    /// The models each agent offers, from the same catalogs the composer reads.
    let models: (String) -> [ModelChoice]
    /// The model whose effort levels apply when the caller knows it better than the selection does:
    /// a live session's runtime reports the model behind "Use CLI Settings".
    var effortModel: ModelChoice?
    /// Under "Use CLI Settings": what the runtime is actually running, when known.
    var cliSettingsDetail: String?
    /// Offered only where the session can carry it (a live Claude session, not a pending switch).
    var ultracode: Binding<Bool>?
    /// Explains when the choice applies ("Applies from your next message.").
    var footer: String?
    /// The Agent section's title.
    var agentSectionTitle: LocalizedStringKey = "Agent"
    /// Your agents, offered above the bare providers (a live conversation's picker only).
    var profiles: [AgentProfile] = []
    /// The agent the live conversation works as, tagged "Current"; nil when it's a bare provider.
    var currentProfile: AgentIdentity?
    /// Whether the machine can switch the conversation to an agent; where it can't, the agents other
    /// than the current one are unavailable and `agentsFooter` says why.
    var agentsSelectable = true
    var agentsFooter: String?

    var body: some View {
        let choices = models(choice.agentId)
        let model = effortModel ?? choices.first { $0.id == choice.modelId }
        List {
            if !profiles.isEmpty {
                Section {
                    ForEach(profiles) { profile in
                        profileRow(profile)
                    }
                } header: {
                    Text("Agents")
                } footer: {
                    if let agentsFooter { Text(agentsFooter) }
                }
            }
            Section {
                ForEach(agents, id: \.self) { agent in
                    Button {
                        guard agent != choice.agentId || choice.profileId != nil else { return }
                        AppHaptics.selection()
                        choice = AgentModelChoice(agentId: agent)
                    } label: {
                        HStack(spacing: 10) {
                            Image("Agents/\(agent)").resizable().scaledToFit().frame(width: 18, height: 18)
                            Text(Agent.displayNames[agent] ?? agent).foregroundStyle(.primary)
                            if agent == currentAgentId, currentProfile == nil { Text("Current").font(.footnote).foregroundStyle(.secondary) }
                            Spacer()
                            check(agent == choice.agentId && choice.profileId == nil)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            } header: {
                Text(profiles.isEmpty ? agentSectionTitle : "Providers")
            } footer: {
                // Leaving the agent the conversation works as for a bare provider.
                if let currentProfile, choice.profileId == nil {
                    Text("This session will stop working as \(currentProfile.name).")
                }
            }
            Section {
                modelRow(id: "default", name: String(localized: "Use CLI Settings"),
                         detail: cliSettingsDetail ?? String(localized: "Models configured in the CLI"))
                ForEach(choices) { item in
                    modelRow(id: item.id, name: item.name, detail: item.description ?? item.id)
                }
            } header: {
                Text("Model")
            } footer: {
                if let footer { Text(footer) }
            }
            if let model, !model.effortLevels.isEmpty {
                Section("Effort") {
                    EffortSlider(levels: model.effortLevels, selection: choice.effort ?? model.defaultEffort ?? model.effortLevels[0]) { level in
                        choice.effort = level
                    }
                    .padding(.vertical, 8)
                    if model.supportsUltracode, let ultracode {
                        Toggle(isOn: ultracode) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Ultracode", systemImage: "sparkles")
                                Text("Maximum reasoning with dynamic workflows (forces XHigh effort).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: choice)
    }

    private func profileRow(_ profile: AgentProfile) -> some View {
        let isCurrent = profile.id == currentProfile?.id
        return Button {
            guard profile.id != choice.profileId else { return }
            AppHaptics.selection()
            // The agent's own model and effort, changeable below.
            choice = AgentModelChoice(agentId: profile.providerId, modelId: profile.modelId ?? "default",
                                      effort: profile.effort, profileId: profile.id)
        } label: {
            HStack(spacing: 10) {
                AgentIcon(emoji: profile.emoji)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(profile.name).foregroundStyle(.primary).lineLimit(1)
                        if isCurrent { Text("Current").font(.footnote).foregroundStyle(.secondary) }
                    }
                    Text(Agent.displayNames[profile.providerId] ?? profile.providerId)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                ProviderLogo(providerId: profile.providerId, size: 16)
                check(profile.id == choice.profileId)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        // Going back to the current agent stays possible: it cancels a switch.
        .disabled(!agentsSelectable && !isCurrent)
    }

    private func modelRow(id: String, name: String, detail: String) -> some View {
        Button {
            guard id != choice.modelId else { return }
            AppHaptics.selection()
            // The effort stays while the new model offers it; otherwise that model's own default.
            let next = models(choice.agentId).first { $0.id == id }
            choice.modelId = id
            if let effort = choice.effort, next?.effortLevels.contains(effort) != true { choice.effort = nil }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                check(choice.modelId == id)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    @ViewBuilder
    private func check(_ on: Bool) -> some View {
        if on { Image(systemName: "checkmark").foregroundStyle(Color.userBubble).fontWeight(.semibold) }
    }
}

/// A live conversation's picker: picking its own agent changes the session's model and effort right
/// away; picking another agent arms a switch, and the next message moves the conversation to that
/// agent (with the model and effort chosen for it) via `session.agentTransition`.
struct SessionModelPicker: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var installed: Set<String>?

    private var session: Session? { store.sessions[sessionId] }

    private var agents: [String] {
        let known = installed ?? Set([session?.agentId].compactMap { $0 })
        return Agent.ids.filter { known.contains($0) && $0 != "customAcp" }
    }

    /// Your agents whose provider this machine has, in the list's order (and the current one always).
    private func profiles(current: AgentIdentity?) -> [AgentProfile] {
        let providers = Set(agents)
        return AgentRoster.ordered(store.agentProfiles, by: store.accountSettings?.agentOrder ?? [])
            .filter { providers.contains($0.providerId) || $0.id == current?.id }
    }

    var body: some View {
        if let controls = store.controls(for: sessionId), let current = session?.agentId {
            let armed = store.armedAgents[sessionId]
            let sessions = Array(store.sessions.values)
            let identity = session?.agentIdentity
            let identitySupport = session?.machineId.flatMap { store.agentIdentitySwitchSupport[$0] }
            AgentModelPicker(
                agents: agents,
                currentAgentId: current,
                choice: Binding(
                    get: {
                        if let armed {
                            return AgentModelChoice(agentId: armed.agentId, modelId: armed.modelId ?? "default", effort: armed.effort,
                                                    profileId: armed.profile?.id)
                        }
                        return AgentModelChoice(agentId: current, modelId: controls.selectedModelId, effort: controls.effort, profileId: identity?.id)
                    },
                    set: { next in apply(next, controls: controls, current: current, currentProfileId: identity?.id, wasArmed: armed != nil) }),
                models: { agent in
                    agent == current ? controls.models : SessionControls.newSessionModels(agentId: agent, sessions: sessions)
                },
                effortModel: armed == nil ? controls.effortModel : nil,
                cliSettingsDetail: armed == nil ? controls.appliedModelId.map { String(localized: "Running: \(controls.modelName($0))") } : nil,
                ultracode: armed == nil && controls.effortModel?.supportsUltracode == true
                    ? Binding(get: { controls.ultracode ?? false }, set: { on in Task { await store.setUltracode(on, in: sessionId) } })
                    : nil,
                footer: armed.map { String(localized: "Your next message switches this session to \($0.profile?.name ?? Agent.displayNames[$0.agentId] ?? $0.agentId), keeping the conversation.") }
                    ?? String(localized: "Applies from your next message."),
                profiles: profiles(current: identity),
                currentProfile: identity,
                // Unknown until the machine answers: an agent isn't offered before it's known to work.
                agentsSelectable: identitySupport == true,
                agentsFooter: identitySupport == false
                    ? String(localized: "Switching this session to an agent needs a newer Happier on its machine. You can still switch providers.")
                    : nil)
            .task(id: session?.machineId) {
                guard let machineId = session?.machineId else { return }
                async let support = store.supportsAgentIdentitySwitch(on: machineId)
                installed = await store.installedAgents(on: machineId)
                _ = await support
            }
        }
    }

    private func apply(_ next: AgentModelChoice, controls: SessionControls, current: String, currentProfileId: String?, wasArmed: Bool) {
        guard next.agentId == current, next.profileId == currentProfileId else {
            if let profileId = next.profileId, let profile = store.agentProfile(id: profileId) {
                // An agent keeps "default" as picked: its own model is already in the choice.
                store.armAgent(.init(profile: profile, modelId: next.modelId, effort: next.effort), for: sessionId)
            } else {
                store.armAgent(.init(agentId: next.agentId, modelId: next.modelId == "default" ? nil : next.modelId, effort: next.effort), for: sessionId)
            }
            return
        }
        // Back to the session's own agent: the switch is off and its model and effort stay as they were.
        if wasArmed { store.armAgent(nil, for: sessionId); return }
        if next.modelId != controls.selectedModelId { Task { await store.setModel(next.modelId, in: sessionId) } }
        if let effort = next.effort, effort != controls.effort { Task { await store.setEffort(effort, in: sessionId) } }
    }

    /// "Codex · GPT-6 · High" (or the agent's name for the provider) for the composer's model pill
    /// while a switch is armed.
    static func label(_ selection: HappierStore.AgentSelection, sessions: [Session]) -> String {
        let agent = selection.profile?.name ?? Agent.displayNames[selection.agentId] ?? selection.agentId
        guard let id = selection.modelId, id != "default",
              let model = SessionControls.newSessionModels(agentId: selection.agentId, sessions: sessions).first(where: { $0.id == id })
        else { return agent }
        return [agent, model.name, model.effortLevels.isEmpty ? nil : EffortSlider.name(selection.effort ?? model.defaultEffort ?? model.effortLevels[0])]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// The picker as a sheet: title and a Close button.
struct ModelPickerSheet<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Select Model")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Read dismissal from the sheet's root, before its NavigationStack.
                        // This also closes a picker presented by the new-session sheet.
                        Button(role: .close) {
                            AppHaptics.light()
                            dismiss()
                        }
                    }
                }
        }
    }
}
