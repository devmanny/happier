import HappierKit
import SwiftUI

/// Which sessions the list shows: shortcuts at the top, then each dimension, combinable, and a
/// way back to the usual list. Every change applies at once and is remembered on this device.
struct SessionFilterView: View {
    @Binding var filter: SessionListFilter
    /// Agents to filter by, id to name.
    let agents: [String: String]
    @Environment(\.dismiss) private var dismiss
    @Environment(HappierStore.self) private var store
    /// The providers and models the listed sessions run on, read once when the filter opens.
    @State private var models = SessionListFilter.ModelOptions(sessions: [])

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(SessionListFilter.shortcuts) { shortcut in
                        Button {
                            AppHaptics.selection()
                            filter = shortcut.filter
                        } label: {
                            HStack {
                                Text(shortcut.title).foregroundStyle(.primary)
                                Spacer()
                                if filter == shortcut.filter {
                                    Image(systemName: "checkmark").foregroundStyle(Color.userBubble).fontWeight(.semibold)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(filter == shortcut.filter ? .isSelected : [])
                        .accessibilityIdentifier("session-filter-shortcut-\(shortcut.id)")
                    }
                } footer: {
                    Text("A tap on the filter button switches between this filter and the usual list.")
                }
                Section("Type") {
                    ForEach(SessionListFilter.Kind.allCases) { kind in
                        Toggle(kind.label, isOn: member(kind, of: \.kinds))
                            .disabled(filter.kinds == [kind])
                    }
                }
                Section("State") {
                    ForEach(SessionListFilter.State.allCases) { state in
                        Toggle(state.label, isOn: member(state, of: \.states))
                            .disabled(filter.states == [state])
                    }
                }
                Section {
                    Toggle("Only what needs me", isOn: $filter.attentionOnly)
                } footer: {
                    Text("Sessions waiting for you, unread, or with open tasks.")
                }
                Section("Agent") {
                    Picker("Agent", selection: $filter.agent) {
                        Text("All").tag(SessionListFilter.AgentChoice.all)
                        ForEach(agents.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }, id: \.key) { id, name in
                            Text(name).tag(SessionListFilter.AgentChoice.agent(id))
                        }
                        Text("No agent").tag(SessionListFilter.AgentChoice.none)
                    }
                    #if os(iOS)
                    .pickerStyle(.navigationLink)
                    #endif
                }
                Section {
                    Picker("Provider", selection: provider) {
                        Text("All").tag(String?.none)
                        ForEach(providerChoices, id: \.self) { id in
                            Text(Agent.displayNames[id] ?? id).tag(String?.some(id))
                        }
                    }
                    Picker("Model", selection: model) {
                        ForEach(modelChoices, id: \.pick) { choice in
                            Text(choice.label).tag(choice.pick)
                        }
                    }
                    #if os(iOS)
                    .pickerStyle(.navigationLink)
                    #endif
                } header: {
                    Text("Model")
                } footer: {
                    Text("A family shows every version of it; the search also finds sessions by model.")
                }
                Section {
                    Button("Reset to Default", systemImage: "arrow.counterclockwise") {
                        AppHaptics.light()
                        filter = .default
                    }
                    .disabled(filter.isDefault)
                } footer: {
                    Text("The default shows active, resting and stopped sessions, without the ones tasks started.")
                }
            }
            .formStyle(.grouped)
            // Switches in neutral gray: a filter is a choice, not a state to color.
            .tint(.gray)
            .navigationTitle("Filter Sessions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { models = SessionListFilter.ModelOptions(sessions: store.sessionList) }
        }
    }

    // MARK: Provider and model

    /// What the model picker holds: every model, a whole family, or one exact model of it.
    private enum ModelPick: Hashable {
        case all
        case family(String)
        case exact(family: String, id: String)
    }

    private var picked: ModelPick {
        guard let family = filter.modelFamily else { return .all }
        return filter.modelId.map { .exact(family: family, id: $0) } ?? .family(family)
    }

    /// The providers with sessions, and the chosen one even when none is left.
    private var providerChoices: [String] {
        models.providers + [filter.provider].compactMap { $0 }.filter { !models.providers.contains($0) }
    }

    /// "All", then each family the provider's sessions run on followed by its versions, newest
    /// first; the chosen model stays in the list even when no session runs on it anymore.
    private var modelChoices: [(label: String, pick: ModelPick)] {
        var choices: [(label: String, pick: ModelPick)] = [(String(localized: "All"), .all)]
        for family in models.families(for: filter.provider) {
            choices.append((String(localized: "Any \(family.word)"), .family(family.word)))
            choices += family.models.map { ($0.name, .exact(family: family.word, id: $0.id)) }
        }
        var seen: Set<ModelPick> = []
        choices = choices.filter { seen.insert($0.pick).inserted }
        if !seen.contains(picked) {
            switch picked {
            case .all: break
            case .family(let word): choices.append((String(localized: "Any \(word)"), picked))
            case .exact(_, let id): choices.append((RunningModel.name(for: id), picked))
            }
        }
        return choices
    }

    private var provider: Binding<String?> {
        Binding(get: { filter.provider }, set: { provider in
            AppHaptics.selection()
            var next = filter
            next.provider = provider
            // A model of another provider would leave the list empty.
            if let family = next.modelFamily, !models.families(for: provider).contains(where: { $0.word == family }) {
                next.modelFamily = nil
                next.modelId = nil
            }
            filter = next
        })
    }

    private var model: Binding<ModelPick> {
        Binding(get: { picked }, set: { pick in
            AppHaptics.selection()
            var next = filter
            switch pick {
            case .all: (next.modelFamily, next.modelId) = (nil, nil)
            case .family(let word): (next.modelFamily, next.modelId) = (word, nil)
            case .exact(let family, let id): (next.modelFamily, next.modelId) = (family, id)
            }
            filter = next
        })
    }

    /// One value of a set dimension as a switch.
    private func member<Value: Hashable>(_ value: Value, of path: WritableKeyPath<SessionListFilter, Set<Value>>) -> Binding<Bool> {
        Binding(get: { filter[keyPath: path].contains(value) }, set: { on in
            AppHaptics.selection()
            var next = filter
            if on { next[keyPath: path].insert(value) } else { next[keyPath: path].remove(value) }
            filter = next
        })
    }
}
