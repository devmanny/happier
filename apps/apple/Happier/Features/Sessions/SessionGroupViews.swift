import HappierKit
import SwiftUI

/// A session row's "Move to Group": the user's groups (the one it's in checked) and a new one, then
/// taking it out of a group it's in of its own accord (one listed under a session in a group goes
/// with that session). Groups are the account's (`SessionGroup`), the same on every device.
struct SessionGroupMenu: View {
    let session: Session
    let store: HappierStore
    /// Asks the name of a new group to put the session in.
    let newGroup: () -> Void

    var body: some View {
        let current = store.groupId(of: session.id)
        Menu {
            ForEach(store.sessionGroups) { group in
                Button {
                    guard current != group.id else { return }
                    AppHaptics.selection()
                    Task { await store.moveToGroup(session.id, group.id) }
                } label: {
                    if current == group.id {
                        Label(group.name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: group.name)
                    }
                }
            }
            if !store.sessionGroups.isEmpty { Divider() }
            Button("New Group…", systemImage: "plus") {
                AppHaptics.light()
                newGroup()
            }
            .accessibilityIdentifier("session-new-group")
        } label: {
            Label("Move to Group", systemImage: "rectangle.stack")
        }
        .accessibilityIdentifier("session-move-to-group")
        if store.isGroupedOnItsOwn(session.id) {
            Button("Remove from Group", systemImage: "rectangle.stack.badge.minus") {
                AppHaptics.selection()
                Task { await store.moveToGroup(session.id, nil) }
            }
        }
    }
}

/// The session list's group prompts: naming a new group for a session, renaming one, deleting one.
struct SessionGroupAlerts: ViewModifier {
    @Binding var newGroupFor: Session?
    @Binding var renaming: SessionGroup?
    @Binding var deleting: SessionGroup?
    @Environment(HappierStore.self) private var store
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("New Group", isPresented: Binding(get: { newGroupFor != nil }, set: { if !$0 { newGroupFor = nil } }),
                   presenting: newGroupFor) { session in
                TextField("Name", text: $name)
                Button("Create") {
                    AppHaptics.confirm()
                    let name = name
                    Task { await store.moveToNewGroup(session.id, named: name) }
                }
                .disabled(SessionGroup.cleanName(name) == nil)
                Button("Cancel", role: .cancel) { AppHaptics.light() }
            } message: { _ in
                Text("The session moves into it.")
            }
            .alert("Rename Group", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                   presenting: renaming) { group in
                TextField("Name", text: $name)
                Button("Save") {
                    AppHaptics.confirm()
                    let name = name
                    Task { await store.renameGroup(group.id, to: name) }
                }
                .disabled(SessionGroup.cleanName(name) == nil)
                Button("Cancel", role: .cancel) { AppHaptics.light() }
            }
            .confirmationDialog(Text("Delete “\(deleting?.name ?? "")”?"),
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { group in
                Button("Delete Group", role: .destructive) {
                    AppHaptics.confirm()
                    Task { await store.deleteGroup(group.id) }
                }
                Button("Cancel", role: .cancel) { AppHaptics.light() }
            } message: { _ in
                Text("Its sessions stay in your list.")
            }
            .onChange(of: newGroupFor?.id, initial: true) { name = "" }
            .onChange(of: renaming?.id, initial: true) { name = renaming?.ownName ?? "" }
    }
}
