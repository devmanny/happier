import HappierKit
import SwiftUI

/// "Rooms" in the session list, under the agents: group chats of the user and the agents they
/// invite (`AgentRoom`). A room opens like a session (selected in the sidebar, the chat in the
/// detail; full screen on the iPhone); "+" starts a new one. Shown once there are agents.
struct RoomsSection: View {
    let drawer: Bool
    /// What the list has selected: a session, an agent, or a room (`AgentRoom.selection(id:)`).
    let selection: String?
    /// Opens a room the way the list opens a session.
    let open: (String) -> Void
    /// "+": the list presents "New Room" (a sheet inside the list's rows doesn't reliably show).
    let newRoom: () -> Void
    @Environment(HappierStore.self) private var store

    var body: some View {
        if !store.agentProfiles.isEmpty {
            Section {
                ForEach(store.activeRooms) { room in
                    RoomRow(room: room, drawer: drawer, selected: selection == AgentRoom.selection(id: room.id), open: open)
                }
            } header: {
                HStack {
                    Text("Rooms")
                    Spacer()
                    Button {
                        AppHaptics.light()
                        newRoom()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .textCase(nil)
                    .accessibilityLabel(Text("New Room"))
                    .accessibilityIdentifier("rooms-new")
                }
            }
            .task { await store.refreshRooms() }
        }
    }
}

/// A room in the list: its title over who is in it, with the session rows' look.
private struct RoomRow: View {
    let room: AgentRoom
    let drawer: Bool
    let selected: Bool
    let open: (String) -> Void

    private var selection: String { AgentRoom.selection(id: room.id) }

    var body: some View {
        if drawer {
            Button {
                AppHaptics.selection()
                open(selection)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .sessionListRow(drawer: drawer)
            .listRowBackground(selected ? DrawerRowHighlight().fill(Color.primary.opacity(0.1)) : nil)
            .accessibilityIdentifier("room-row-\(room.id)")
        } else {
            label
                .sessionListRow(drawer: drawer)
                .tag(selection)
                .accessibilityIdentifier("room-row-\(room.id)")
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: SessionListView.drawerAvatar, height: SessionListView.drawerAvatar)
                .glassEffect(.regular, in: Circle())
                .padding(.trailing, SessionListView.avatarGap - 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(room.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(room.members.map { [$0.emoji, $0.name ?? $0.agentId].compactMap { $0 }.joined(separator: " ") }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if room.isPaused {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Paused"))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
