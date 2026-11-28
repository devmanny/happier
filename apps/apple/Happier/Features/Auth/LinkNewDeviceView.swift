import HappierKit
import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// Settings → Account → Link New Device: the other half of "Link with Another Device". Scan the
/// code the new device shows (or paste its link on a Mac) and it signs in to this account.
struct LinkNewDeviceView: View {
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var approving = false
    @State private var linked = false
    @State private var error: String?
    /// A computer's `happier auth login` code scanned here instead (`useScannedAuthUrlProcessor`).
    @State private var computer: ConnectComputerView.Selection?

    var body: some View {
        Form {
            if linked {
                Section {
                    Label("Device linked. It's signing in now.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                #if os(iOS)
                if DataScannerViewController.isSupported {
                    Section {
                        QRCodeScanner { code in approve(code, scanned: true) }
                            .frame(height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .listRowInsets(EdgeInsets())
                            .overlay { if approving { HappierSpinner(size: HappierSpinner.hero) } }
                    } footer: {
                        Text("On the other device, choose Link with Another Device and point this camera at its code.")
                    }
                }
                #endif
                Section {
                    TextField("happier:///account?…", text: $pasted)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit { approve(pasted) }
                    Button("Link Device") { approve(pasted) }
                        .disabled(approving || pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Or Paste Its Link")
                } footer: {
                    Text("The new device gets full access to your sessions, like this one.")
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Link New Device")
        .sheetCloseButton()
        .navigationDestination(item: $computer) { selection in
            TerminalConnectView(link: selection.link, allowsLoopbackRelay: selection.allowsLoopbackRelay) { dismiss() }
        }
    }

    private func approve(_ link: String, scanned: Bool = false) {
        guard !approving, !linked, computer == nil else { return }
        if let terminal = TerminalConnectLink(link) {
            AppHaptics.light()
            computer = .init(link: terminal, allowsLoopbackRelay: !scanned)
            return
        }
        approving = true
        error = nil
        Task {
            do {
                try await store.approveDeviceLink(link)
                AppHaptics.success()
                withAnimation(.smooth) { linked = true }
                try? await Task.sleep(for: .seconds(1.5))
                dismiss()
            } catch {
                AppHaptics.error()
                self.error = error.localizedDescription
            }
            approving = false
        }
    }
}
