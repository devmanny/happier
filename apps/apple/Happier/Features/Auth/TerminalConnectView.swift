import HappierKit
import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// Confirms signing in the computer that ran `happier auth login` (`terminal/connect.tsx` in the
/// web app): which relay, until when, then Connect or Cancel, and what came of it.
struct TerminalConnectView: View {
    let link: TerminalConnectLink
    /// A loopback relay is followed from an opened or pasted link, not from a scanned code.
    let allowsLoopbackRelay: Bool
    /// Closes the flow (Cancel, Done).
    let onDone: () -> Void
    @Environment(HappierStore.self) private var store
    @State private var connecting = false
    @State private var outcome: Outcome?

    enum Outcome: Equatable {
        case connected, alreadyUsed, expired
        case failed(String)
    }

    private var relay: URL { store.terminalConnectRelay(for: link, allowsLoopback: allowsLoopbackRelay) }
    private var switchesRelay: Bool { RelayList.canonical(relay) != RelayList.canonical(store.server) }

    var body: some View {
        // Each second, so Connect turns off once the link expires.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Form {
                details
                if let outcome {
                    result(outcome)
                } else {
                    actions(expired: link.expiresAt.map { $0 <= context.date } ?? false)
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Connect Computer")
    }

    private var details: some View {
        Section {
            LabeledContent("Relay") {
                Text(relay.host() ?? relay.absoluteString)
            }
            if switchesRelay {
                Label("This computer uses another relay. Happier will switch to it.", systemImage: "arrow.triangle.swap")
                    .foregroundStyle(.secondary)
            }
            if let expiresAt = link.expiresAt {
                LabeledContent("Expires") {
                    Text(expiresAt, format: .relative(presentation: .named))
                }
            }
            LabeledContent("Computer Key") {
                Text(Base64.urlEncoded(link.publicKey).prefix(12) + "…")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        } footer: {
            Text("The computer gets full access to your sessions, like this device. Your keys reach it end-to-end encrypted.")
        }
    }

    @ViewBuilder
    private func actions(expired: Bool) -> some View {
        Section {
            Button {
                connect()
            } label: {
                HStack {
                    Text("Connect")
                    if connecting {
                        Spacer()
                        HappierSpinner(size: HappierSpinner.mini)
                    }
                }
            }
            .disabled(connecting || expired)
            .accessibilityIdentifier("terminal-connect-approve")
            Button("Cancel", role: .cancel) { onDone() }
                .disabled(connecting)
                .accessibilityIdentifier("terminal-connect-cancel")
        } footer: {
            if expired { Text("This link expired. Run happier auth login on the computer again.") }
        }
    }

    @ViewBuilder
    private func result(_ outcome: Outcome) -> some View {
        Section {
            switch outcome {
            case .connected:
                Label("Computer connected. It's signing in now.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .alreadyUsed:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connection Already Used").font(.headline)
                    Text("This connection link was already used by another device. To connect multiple devices to the same terminal, sign out and log in to the same account on all devices.")
                        .foregroundStyle(.secondary)
                }
            case .expired:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connection Expired").font(.headline)
                    Text("This connection link has expired. Run happier auth login on the computer again.")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
            Button(outcome == .connected ? "Done" : "Close") { onDone() }
                .accessibilityIdentifier("terminal-connect-done")
        }
    }

    private func connect() {
        guard !connecting else { return }
        connecting = true
        Task {
            defer { connecting = false }
            do {
                switch try await store.approveTerminalConnect(link, allowsLoopback: allowsLoopbackRelay) {
                case .approved:
                    AppHaptics.success()
                    withAnimation(.smooth) { outcome = .connected }
                case .alreadyUsed:
                    AppHaptics.error()
                    withAnimation(.smooth) { outcome = .alreadyUsed }
                case .expired:
                    AppHaptics.error()
                    withAnimation(.smooth) { outcome = .expired }
                case .needsSignIn:
                    // The sign-in screen opens on that relay; this link comes back once signed in.
                    break
                }
            } catch {
                guard !UserFacingError.isSilent(error) else { return }
                AppHaptics.error()
                withAnimation(.smooth) { outcome = .failed(UserFacingError.message(for: error, hasNetworkPath: store.hasNetworkPath)) }
            }
        }
    }
}

/// Machines → Connect Computer: scan the code `happier auth login` shows (iPhone, iPad) or paste
/// the link it prints, then confirm.
struct ConnectComputerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var selection: Selection?
    @State private var error: String?

    struct Selection: Hashable {
        let link: TerminalConnectLink
        let allowsLoopbackRelay: Bool
    }

    var body: some View {
        Form {
            #if os(iOS)
            if DataScannerViewController.isSupported {
                Section {
                    QRCodeScanner { code in open(code, scanned: true) }
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Run happier auth login on the computer, then point this camera at the code it shows.")
                }
            }
            #endif
            Section {
                TextField("happier://terminal?…", text: $pasted)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { open(pasted, scanned: false) }
                    .accessibilityIdentifier("terminal-connect-link")
                Button("Continue") { open(pasted, scanned: false) }
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Or Paste Its Link")
            } footer: {
                Text("happier auth login prints a link next to its code; either one works.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connect Computer")
        .sheetCloseButton()
        .navigationDestination(item: $selection) { selection in
            TerminalConnectView(link: selection.link, allowsLoopbackRelay: selection.allowsLoopbackRelay) { dismiss() }
        }
    }

    private func open(_ text: String, scanned: Bool) {
        guard selection == nil else { return }
        guard let link = TerminalConnectLink(text) else {
            AppHaptics.error()
            error = String(localized: "That isn't a computer's sign-in code. Run happier auth login on the computer and use the code or link it shows.")
            return
        }
        AppHaptics.light()
        error = nil
        selection = Selection(link: link, allowsLoopbackRelay: !scanned)
    }
}
