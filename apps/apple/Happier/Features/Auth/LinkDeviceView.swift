import CoreImage.CIFilterBuiltins
import HappierKit
import SwiftUI

/// New device shows a QR; a signed-in device scans it from Settings → Account → Link New Device.
struct LinkDeviceView: View {
    let server: URL
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var linkURL: String?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("Scan this code from a device where you're already signed in to Happier.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Label(server.host() ?? server.absoluteString, systemImage: "server.rack")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white)
                if let linkURL, let image = QRCode.image(for: linkURL) {
                    image
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(20)
                        .transition(.opacity)
                } else if error == nil {
                    HappierSpinner(size: 36, color: .gray)
                }
            }
            .frame(width: 260, height: 260)
            .shadow(color: .black.opacity(0.08), radius: 20, y: 8)

            VStack(alignment: .leading, spacing: 10) {
                Label("Open Happier on your other device", systemImage: "1.circle.fill")
                Label("Go to Settings → Account", systemImage: "2.circle.fill")
                Label("Tap Link New Device and scan", systemImage: "3.circle.fill")
            }
            .font(.callout)

            if let error {
                VStack(spacing: 8) {
                    Text(error).foregroundStyle(.red).font(.footnote).multilineTextAlignment(.center)
                    Button("Try Again") { attempt += 1 }
                }
            } else if linkURL != nil {
                Label("Waiting for approval…", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse)
            }
            Spacer()
        }
        .padding(24)
        .navigationTitle("Link Device")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
        .task(id: attempt) { await link() }
    }

    private func link() async {
        error = nil
        linkURL = nil
        let auth = AuthAPI(server: server)
        do {
            let pair = try await auth.startAccountLink()
            withAnimation { linkURL = pair.accountLinkURL }
            let credentials = try await auth.waitForApproval(pair)
            try store.signIn(credentials, server: server)
            dismiss()
        } catch is CancellationError {
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}

enum QRCode {
    static func image(for text: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return Image(decorative: cg, scale: 1)
    }
}
