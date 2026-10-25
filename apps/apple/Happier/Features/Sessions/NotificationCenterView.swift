import HappierKit
import SwiftUI

/// The bell's list: the app's notifications, newest first, one per session. Opening one goes to its
/// conversation; answering is left to the system notification's Reply.
struct NotificationCenterView: View {
    @Environment(NotificationInbox.self) private var inbox
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(visible) { notification in
                    Button { open(notification) } label: {
                        NotificationRow(notification: notification)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(notification) }
                    }
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(notification) }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.plain)
            #endif
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView("No Notifications", systemImage: "bell.slash",
                                           description: Text("What your sessions tell you shows up here."))
                }
            }
            .refreshable { await inbox.refresh() }
            .navigationTitle("Notifications")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear All", role: .destructive) {
                        withAnimation(.smooth) { inbox.removeAll() }
                    }
                    .disabled(visible.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
            }
        }
        .task { await inbox.refresh() }
    }

    /// A session archived here drops out at once; its copy on the device goes with the next refresh.
    private var visible: [DeliveredNotification] {
        inbox.notifications.filter { notification in
            notification.sessionId.map { store.sessions[$0]?.archivedAt == nil } ?? true
        }
    }

    private func open(_ notification: DeliveredNotification) {
        inbox.remove(notification)
        dismiss()
        guard let sessionId = notification.sessionId else { return }
        Task { await store.handle(PushTap(sessionId: sessionId, permission: nil)) }
    }

    private func delete(_ notification: DeliveredNotification) {
        withAnimation(.smooth) { inbox.remove(notification) }
    }
}

private struct NotificationRow: View {
    let notification: DeliveredNotification
    @Environment(HappierStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The session's agent; a notification without one sits on the same glass disc.
            AgentAvatar(agentId: notification.sessionId.flatMap { store.sessions[$0]?.agentId }, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(notification.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(ChatDate.listLabel(notification.date))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(notification.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
