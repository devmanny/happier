import HappierKit
import SwiftUI

/// What the model picker edits: an agent, its model (`"default"` keeps the agent's CLI settings)
/// and, when that model has levels, the effort to run it at.
struct AgentModelChoice: Equatable {
    var agentId: String
    var modelId = "default"
    var effort: String?
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
    /// Sections shown first (a new session's "Who's working?").
    var leading: AnyView?
    /// The Agent section's title.
    var agentSectionTitle: LocalizedStringKey = "Agent"

    var body: some View {
        let choices = models(choice.agentId)
        let model = effortModel ?? choices.first { $0.id == choice.modelId }
        List {
            if let leading { leading }
            Section(agentSectionTitle) {
                ForEach(agents, id: \.self) { agent in
                    Button {
                        guard agent != choice.agentId else { return }
                        AppHaptics.selection()
                        choice = AgentModelChoice(agentId: agent)
                    } label: {
                        HStack(spacing: 10) {
                            Image("Agents/\(agent)").resizable().scaledToFit().frame(width: 18, height: 18)
                            Text(Agent.displayNames[agent] ?? agent).foregroundStyle(.primary)
                            if agent == currentAgentId { Text("Current").font(.footnote).foregroundStyle(.secondary) }
                            Spacer()
                            check(agent == choice.agentId)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
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

    var body: some View {
        if let controls = store.controls(for: sessionId), let current = session?.agentId {
            let armed = store.armedAgents[sessionId]
            let sessions = Array(store.sessions.values)
            AgentModelPicker(
                agents: agents,
                currentAgentId: current,
                choice: Binding(
                    get: {
                        if let armed { return AgentModelChoice(agentId: armed.agentId, modelId: armed.modelId ?? "default", effort: armed.effort) }
                        return AgentModelChoice(agentId: current, modelId: controls.selectedModelId, effort: controls.effort)
                    },
                    set: { next in apply(next, controls: controls, current: current, wasArmed: armed != nil) }),
                models: { agent in
                    agent == current ? controls.models : SessionControls.newSessionModels(agentId: agent, sessions: sessions)
                },
                effortModel: armed == nil ? controls.effortModel : nil,
                cliSettingsDetail: armed == nil ? controls.appliedModelId.map { String(localized: "Running: \(controls.modelName($0))") } : nil,
                ultracode: armed == nil && controls.effortModel?.supportsUltracode == true
                    ? Binding(get: { controls.ultracode ?? false }, set: { on in Task { await store.setUltracode(on, in: sessionId) } })
                    : nil,
                footer: armed.map { String(localized: "Your next message switches this session to \(Agent.displayNames[$0.agentId] ?? $0.agentId), keeping the conversation.") }
                    ?? String(localized: "Applies from your next message."))
            .task(id: session?.machineId) {
                guard let machineId = session?.machineId else { return }
                installed = await store.installedAgents(on: machineId)
            }
        }
    }

    private func apply(_ next: AgentModelChoice, controls: SessionControls, current: String, wasArmed: Bool) {
        guard next.agentId == current else {
            store.armAgent(.init(agentId: next.agentId, modelId: next.modelId == "default" ? nil : next.modelId, effort: next.effort), for: sessionId)
            return
        }
        // Back to the session's own agent: the switch is off and its model and effort stay as they were.
        if wasArmed { store.armAgent(nil, for: sessionId); return }
        if next.modelId != controls.selectedModelId { Task { await store.setModel(next.modelId, in: sessionId) } }
        if let effort = next.effort, effort != controls.effort { Task { await store.setEffort(effort, in: sessionId) } }
    }

    /// "Codex · GPT-6 · High" for the composer's model pill while a switch is armed.
    static func label(_ selection: HappierStore.AgentSelection, sessions: [Session]) -> String {
        let agent = Agent.displayNames[selection.agentId] ?? selection.agentId
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
