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
                        LinkCodeScanner { code in approve(code) }
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
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { SheetCloseButton() }
        }
    }

    private func approve(_ link: String) {
        guard !approving, !linked else { return }
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

#if os(iOS)
/// Apple's live camera scanner, reporting the first QR it reads (each new one after that).
private struct LinkCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        // Starting before the view is on screen can fail; try again once it is.
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in addedItems {
                if let text = code.payloadStringValue { onCode(text); return }
            }
        }
    }
}
#endif
