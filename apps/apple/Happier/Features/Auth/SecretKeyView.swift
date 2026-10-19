import HappierKit
import SwiftUI

/// Restore with the backup secret key (`XXXXX-XXXXX-…`), as in the official app's manual restore.
struct SecretKeyView: View {
    let server: URL
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField("XXXXX-XXXXX-XXXXX-…", text: $key, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(2...4)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .focused($focused)
            } footer: {
                Text("Your secret key is in Settings → Account on a signed-in device. It never leaves this device.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Secret Key")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if working { ProgressView() } else {
                    Button("Sign In") { Task { await signIn() } }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func signIn() async {
        working = true
        defer { working = false }
        do {
            let secret = try SecretKeyFormat.parse(key)
            let credentials = try await AuthAPI(server: server).signIn(secret: secret)
            try store.signIn(credentials, server: server)
            dismiss()
        } catch is SecretKeyFormat.InvalidKey {
            error = "That doesn't look like a valid secret key."
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}
