import HappierKit
import SwiftUI

/// An agent's own chat, opened by its circle in the sidebar, like a conversation in Messages: its
/// photo and name on top (tap them for its card, `AgentProfileView`: beside the chat on iPad and Mac,
/// a sheet on the iPhone; the card draws its own Close and Edit), and the chat itself (`RoomView` of
/// its `AgentRoom.isDirect` room), made the first time where the agent last worked
/// (`AgentRoom.directPlacement`). Everything written there reaches it.
struct AgentChatView: View {
    let agentId: String
    @Environment(HappierStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    /// Made but not opened yet: no machine to work on, or the write failed (already reported).
    @State private var failed = false
    @State private var showInfo = false

    private var profile: AgentProfile? { store.agentProfile(id: agentId) }
    private var room: AgentRoom? { store.directRoom(agentId: agentId) }

    /// iPad and Mac show the info beside the chat; the iPhone in a sheet.
    private var infoBeside: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        true
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            chat
                .frame(maxWidth: .infinity)
            if infoBeside, showInfo {
                Divider()
                AgentProfileView(agentId: agentId, close: hideInfo)
                    .frame(width: 360)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .toolbar {
            if let profile {
                ToolbarItem(placement: .principal) { header(profile) }
            }
        }
        .task(id: "\(agentId)|\(profile != nil)") { await open() }
        // What each of its threads says it is doing, for the session cards in its replies.
        .task(id: agentId) { await store.refreshAgentMemory(agentId: agentId) }
        .sheet(isPresented: Binding(get: { showInfo && !infoBeside }, set: { if !$0 { showInfo = false } })) {
            AgentProfileView(agentId: agentId, close: hideInfo)
        }
    }

    /// The card's Close: the panel slides away (at once with Reduce Motion), the sheet goes down.
    private func hideInfo() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { showInfo = false }
    }

    @ViewBuilder
    private var chat: some View {
        if let room {
            RoomView(roomId: room.id)
                .id(room.id)
        } else if failed, let profile {
            ContentUnavailableView("Can't Open the Chat", systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                                   description: Text("\(profile.name) needs a computer linked to Happier to work on."))
        } else if store.agentProfiles.isEmpty || profile != nil {
            HappierSpinner(size: HappierSpinner.hero)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Agent Not Found", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("It may have been deleted on another device."))
        }
    }

    /// Its chat, made the first time where it last worked.
    private func open() async {
        guard let profile, room == nil else { return }
        failed = false
        guard let place = AgentRoom.directPlacement(agentId: agentId, sessions: Array(store.sessions.values), machines: store.machines),
              await store.openDirectRoom(with: profile, machineId: place.machineId, directory: place.directory) != nil else {
            failed = true
            return
        }
    }

    /// Its photo over its name, as Messages shows who you're writing to; "Working" while it is.
    private func header(_ profile: AgentProfile) -> some View {
        let summary = AgentRoster.summary(of: profile, sessions: store.sessionList, context: SessionListFilter.Context(tasks: store.tasks),
                                          now: store.presenceDate(.now), usage: { store.usage(for: $0.id) })
        let working = summary.working > 0 || store.roomSeats[room?.id ?? ""]?.contains { $0.inFlight != nil } == true
        return Button {
            AppHaptics.light()
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { showInfo.toggle() }
        } label: {
            HStack(spacing: 8) {
                AgentProfileAvatar(profile: profile, size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        Text(verbatim: profile.name).font(.headline)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if working {
                        Text("Working")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.userBubble)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(working ? "\(profile.name), working" : profile.name))
        .accessibilityHint(Text(showInfo ? "Hides its info" : "Shows its info"))
        .accessibilityIdentifier("agent-chat-header")
    }
}
