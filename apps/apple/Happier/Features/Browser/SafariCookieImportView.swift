import HappierKit
import SwiftUI
#if os(macOS)
import SafariServices
#endif

/// A local review, available from Settings and the extension's UUID-only link.
struct SafariCookieImportView: View {
    var requestID: UUID?
    @Environment(BrowserModel.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var multipleWindows
    @State private var deliveries: [SafariCookieImport] = []
    @State private var busy = false
    @State private var error: String?
    @State private var imported: Int?
    @State private var total = 0
    @State private var importedOrigin: URL?
    @State private var showBrowser = false

    var body: some View {
        Form {
            if let imported {
                Section {
                    Label("Imported \(imported) of \(total) cookies", systemImage: "checkmark.circle")
                    if imported < total {
                        Text("WebKit could not keep every cookie. You may need to sign in again.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Open in Happier", systemImage: "safari") {
                        if let importedOrigin { browser.show(importedOrigin, forSession: nil) }
                        BrowserModel.present(openWindow: openWindow, multipleWindows: multipleWindows, sheet: $showBrowser)
                    }
                }
            } else if deliveries.isEmpty {
                Section {
                    Text("Enable Happier Import in Safari Extensions. Open the website in Safari, select Happier Import and choose Prepare Import. Return here to review it.")
                    #if os(macOS)
                    Button("Open Safari Extension Settings") {
                        SFSafariApplication.showPreferencesForExtension(withIdentifier: "com.devmanny.happier.safari") { _ in }
                    }
                    #endif
                    Button("Check for Import", systemImage: "arrow.clockwise") { load() }
                } header: { Text("Bring a website's cookies") }
            } else {
                ForEach(deliveries) { transfer in
                    Section {
                        LabeledContent("Website", value: transfer.origin.host() ?? "")
                        LabeledContent("Cookies", value: String(transfer.cookies.count))
                        Button("Import into Happier", systemImage: "square.and.arrow.down") {
                            Task { await accept(transfer) }
                        }
                        .disabled(busy)
                        Button("Discard", role: .destructive) { discard(transfer) }.disabled(busy)
                    }
                }
            }
            Section {
                Text("Cookies can keep you signed in. Only cookies for the Safari page you choose are copied, on this device. Some websites still require you to sign in again.")
                if browser.agentAccessEnabled {
                    Text("Agents allowed to use Happier's browser can use these sign-ins too.")
                }
                Text("An import expires after 10 minutes. Closing this review discards any cookies you have not imported.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .formStyle(.grouped)
        .navigationTitle("Import from Safari")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(busy) }
        }
        .interactiveDismissDisabled(busy)
        .task { load() }
        .onDisappear {
            for transfer in deliveries { try? SafariCookieInbox.shared?.remove(transfer.id) }
        }
        .modifier(BrowserSheet(shown: $showBrowser))
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420)
        #endif
    }

    private func load() {
        guard let inbox = SafariCookieInbox.shared else {
            error = "Safari import is unavailable in this build."
            return
        }
        if let requestID {
            do { deliveries = [try inbox.load(requestID)] }
            catch { self.error = "This import is no longer available. Prepare it again in Safari." }
        } else {
            deliveries = inbox.pending()
        }
    }

    private func discard(_ transfer: SafariCookieImport) {
        do {
            try SafariCookieInbox.shared?.remove(transfer.id)
            deliveries.removeAll { $0.id == transfer.id }
        } catch { self.error = "The import could not be discarded. Try again." }
    }

    private func accept(_ transfer: SafariCookieImport) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result = try await browser.importSafariCookies(transfer.id)
            deliveries.removeAll { $0.id == transfer.id }
            imported = result.imported
            total = result.total
            importedOrigin = result.origin
        } catch {
            self.error = "The import could not be completed. Prepare it again in Safari."
            deliveries.removeAll { $0.id == transfer.id }
        }
    }
}
