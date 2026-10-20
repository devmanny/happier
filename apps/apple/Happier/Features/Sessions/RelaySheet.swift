import HappierKit
import SwiftUI

/// The relay (Happier server) this device is connected to, and switching to another one. Each relay
/// keeps its own sign-in, so switching back never asks to sign in again.
struct RelaySheet: View {
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var status: HappierStore.RelayStatus?
    @State private var checking = false
    @State private var addingRelay = false
    @State private var newRelay = ""

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Circle().fill(statusColor).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.server.host() ?? store.server.absoluteString).font(.headline)
                        Text(statusLabel).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Address", value: RelayList.canonical(store.server))
                LabeledContent("Response time") {
                    if checking { HappierSpinner(size: HappierSpinner.mini) } else {
                        Text(status?.responseTime.map(Self.milliseconds) ?? String(localized: "Unreachable"))
                    }
                }
                LabeledContent("Server build") {
                    if checking { HappierSpinner(size: HappierSpinner.mini) } else {
                        Text(status?.build ?? "—").monospaced()
                    }
                }
            } header: {
                Text("Current relay")
            }

            Section {
                ForEach(store.knownServers, id: \.absoluteString) { url in
                    let current = RelayList.canonical(url) == RelayList.canonical(store.server)
                    Button {
                        store.switchServer(to: url)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.host() ?? url.absoluteString).foregroundStyle(.primary)
                                if !current, !store.hasCredentials(for: url) {
                                    Text("Sign in required").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if current { Image(systemName: "checkmark").foregroundStyle(Color.userBubble) }
                        }
                    }
                    .disabled(current)
                }
                Button("Add Relay…", systemImage: "plus") { addingRelay = true }
            } header: {
                Text("Switch relay")
            } footer: {
                Text("Each relay keeps its own sign-in on this device.")
            }
        }
        .navigationTitle("Relay")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task(id: store.server) { await check() }
        .refreshable { await check() }
        .alert("Add Relay", isPresented: $addingRelay) {
            TextField("happier.example.com", text: $newRelay)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            Button("Connect") {
                if let url = ServerAddress.normalize(newRelay) {
                    store.switchServer(to: url)
                    dismiss()
                }
                newRelay = ""
            }
            Button("Cancel", role: .cancel) { newRelay = "" }
        } message: {
            Text("You'll sign in to it if this device hasn't before.")
        }
    }

    private var statusColor: Color {
        switch store.connection {
        case .online: .green
        case .connecting: .yellow
        case .offline: .red
        }
    }

    private var statusLabel: String {
        switch store.connection {
        case .online: String(localized: "Connected")
        case .connecting: String(localized: "Connecting…")
        case .offline: String(localized: "Offline")
        }
    }

    private func check() async {
        checking = true
        status = await HappierStore.relayStatus(store.server)
        checking = false
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return "\(Int(ms.rounded())) ms"
    }
}
