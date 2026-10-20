import HappierKit
import SwiftUI

/// The conversation list, modeled on Messages.
struct SessionListView: View {
    @Environment(HappierStore.self) private var store
    @Binding var selection: String?
    @State private var query = ""
    @State private var showAccount = false
    @State private var showNewSession = false

    private var sessions: [Session] {
        let all = store.sessionList
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(query) || ($0.displayPath ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private func row(_ session: Session) -> some View {
        SessionRow(session: session)
            .tag(session.id)
            .swipeActions(edge: .trailing) {
                Button {
                    Task { await store.archive(session.id) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.indigo)
            }
            .swipeActions(edge: .leading) {
                if session.active {
                    Button {
                        store.requestStop(session.id)
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .tint(.red)
                }
            }
            .contextMenu {
                if session.active {
                    Button("Stop Session", systemImage: "stop.circle", role: .destructive) { store.requestStop(session.id) }
                }
                Button("Archive", systemImage: "archivebox") { Task { await store.archive(session.id) } }
            }
    }

    var body: some View {
        List(selection: $selection) {
            if store.undecryptableSessionCount > 0 {
                Label("\(store.undecryptableSessionCount) sessions can't be read on this device", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if query.isEmpty {
                // Sessions started from inside another session nest under it.
                OutlineGroup(SessionTree.build(sessions, parent: \.parentSessionId, date: \.sortDate), children: \.children) { node in
                    row(node.item)
                }
            } else {
                ForEach(sessions) { session in row(session) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if sessions.isEmpty {
                if store.isLoadingSessions {
                    ProgressView()
                } else if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView("No Sessions", systemImage: "bubble.left.and.text.bubble.right",
                                           description: Text("Start an agent with the Happier CLI on your computer and it will show up here."))
                }
            }
        }
        .navigationTitle("Sessions")
        .searchable(text: $query, prompt: "Search")
        .refreshable { await store.refreshSessions(userInitiated: true) }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionDot(connection: store.connection)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Account", systemImage: "person.crop.circle") { showAccount = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Session", systemImage: "square.and.pencil") { showNewSession = true }
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionView()
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 560)
                #endif
        }
        .sheet(isPresented: $showAccount) {
            NavigationStack { AccountView() }
        }
    }
}

struct SessionRow: View {
    let session: Session
    @Environment(HappierStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(session.unreadSince != nil ? Color.userBubble : .clear)
                    .frame(width: 10, height: 10)
                SessionAvatar(session: session)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(session.title)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let fraction = store.uploadFraction(inSession: session.id) {
                            UploadRing(fraction: fraction)
                        } else {
                            Text(ChatDate.listLabel(session.sortDate, now: context.date))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    StatusLine(session: session, now: context.date)
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StatusLine: View {
    let session: Session
    let now: Date

    var body: some View {
        let path = session.displayPath ?? session.host ?? ""
        switch session.status(at: now) {
        case .permissionRequired:
            line("Needs your approval", icon: "hand.raised.fill", color: .orange)
        case .actionRequired:
            line("Waiting for your answer", icon: "questionmark.bubble.fill", color: .orange)
        case .working:
            line("Working…", icon: "ellipsis", color: .userBubble, effect: true)
        case .failed:
            line("Turn failed", icon: "exclamationmark.triangle.fill", color: .red)
        case .idle, .offline:
            Text(path)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
        }
    }

    private func line(_ text: LocalizedStringKey, icon: String, color: Color, effect: Bool = false) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon)
                .symbolEffect(.variableColor.iterative, isActive: effect)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(color)
        .lineLimit(1)
    }
}

private struct ConnectionDot: View {
    let connection: HappierStore.Connection

    var body: some View {
        let (color, label): (Color, LocalizedStringKey) = switch connection {
        case .online: (.green, "Connected")
        case .connecting: (.yellow, "Connecting…")
        case .offline: (.red, "Offline")
        }
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(Text(label))
            .help(Text(label))
    }
}

struct AccountView: View {
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var revealKey = false

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Address", value: store.server.host() ?? store.server.absoluteString)
                LabeledContent("Status") {
                    switch store.connection {
                    case .online: Text("Connected").foregroundStyle(.green)
                    case .connecting: Text("Connecting…")
                    case .offline: Text("Offline").foregroundStyle(.red)
                    }
                }
            }
            if let secret = store.recoverySecret {
                Section {
                    if revealKey {
                        Text(SecretKeyFormat.format(secret))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    } else {
                        Button("Show Secret Key") { revealKey = true }
                    }
                } header: {
                    Text("Secret Key")
                } footer: {
                    Text("Anyone with this key can read your sessions. Keep it somewhere safe.")
                }
            }
            Section {
                Button("Sign Out", role: .destructive) {
                    dismiss()
                    store.signOut()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}

/// The App Store download indicator: a progress ring around a small stop square.
private struct UploadRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.userBubble.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(Color.userBubble, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: fraction)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.userBubble)
                .frame(width: 6, height: 6)
        }
        .frame(width: 20, height: 20)
        .accessibilityElement()
        .accessibilityLabel(Text("Uploading \(fraction, format: .percent.precision(.fractionLength(0)))"))
    }
}
