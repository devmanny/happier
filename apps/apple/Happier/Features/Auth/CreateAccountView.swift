import HappierKit
import SwiftUI

/// A new account under a new device key (`createAccount` in the official app). The key is the only
/// way back into the account, so it is shown, with a copy button, before the app signs in.
struct CreateAccountView: View {
    let server: URL
    let publishesContentKey: Bool
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var created: (credentials: Credentials, secret: Data)?
    @State private var error: String?
    @State private var working = false
    @State private var copied = false

    var body: some View {
        Form {
            if let created {
                Section {
                    Text(SecretKeyFormat.format(created.secret))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("account-new-secret-key")
                    Button(copied ? "Copied" : "Copy Secret Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        AppHaptics.confirm()
                        MessageClipboard.copy(SecretKeyFormat.format(created.secret))
                        copied = true
                    }
                } header: {
                    Text("Your Secret Key")
                } footer: {
                    Text("Keep it in a password manager. It's the only way to sign in on a new device if you lose this one, and anyone with it can read your sessions. You can see it again in Settings.")
                }
            } else {
                Section {
                    Text("Happier creates a key on this device that encrypts your sessions end to end. No email or password needed.")
                } footer: {
                    Text("Your account lives on \(server.host() ?? server.absoluteString).")
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Account")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if created == nil { Button("Cancel", role: .cancel) { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                if working {
                    HappierSpinner()
                } else if let created {
                    Button("I've Saved It") { finish(created.credentials) }
                        .accessibilityIdentifier("account-finish-create")
                } else {
                    Button("Create") { Task { await create() } }
                        .accessibilityIdentifier("account-create")
                }
            }
        }
        .interactiveDismissDisabled(created != nil)
    }

    private func create() async {
        working = true
        defer { working = false }
        error = nil
        do {
            let result = try await AuthAPI(server: server).createAccount(publishContentKey: publishesContentKey)
            AppHaptics.success()
            created = result
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    private func finish(_ credentials: Credentials) {
        do {
            try store.signIn(credentials, server: server)
            dismiss()
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}
