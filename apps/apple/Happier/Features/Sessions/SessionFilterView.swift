import HappierKit
import SwiftUI

/// Which sessions the list shows: shortcuts at the top, then each dimension, combinable, and a
/// way back to the usual list. Every change applies at once and is remembered on this device.
struct SessionFilterView: View {
    @Binding var filter: SessionListFilter
    /// Agents to filter by, id to name.
    let agents: [String: String]
    @Environment(\.dismiss) private var dismiss

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
                    Button("Reset to Default", systemImage: "arrow.counterclockwise") {
                        AppHaptics.light()
                        filter = .default
                    }
                    .disabled(filter.isDefault)
                } footer: {
                    Text("The default shows active and inactive sessions, without the ones tasks started.")
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
        }
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
