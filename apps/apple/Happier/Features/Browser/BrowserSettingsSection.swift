import SwiftUI

/// Settings → Browser: whether session agents may drive the integrated browser, and its data.
struct BrowserSettingsSection: View {
    @Environment(BrowserModel.self) private var browser
    @AppStorage(BrowserModel.agentAccessKey) private var agentAccess = true
    @State private var confirmingClear = false
    @State private var browserSheet = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some View {
        Section {
            Button("Open Browser", systemImage: "safari") {
                AppHaptics.light()
                BrowserModel.present(openWindow: openWindow, multipleWindows: supportsMultipleWindows, sheet: $browserSheet)
            }
            NavigationLink {
                SafariCookieImportView()
            } label: {
                Label("Import from Safari", systemImage: "square.and.arrow.down")
            }
            Toggle(isOn: $agentAccess) {
                Label("Agents Can Use the Browser", systemImage: "safari")
            }
            .onChange(of: agentAccess) { browser.updateSlots() }
            Button("Clear Browsing Data", systemImage: "trash", role: .destructive) {
                confirmingClear = true
            }
            .confirmationDialog("Clear cookies, logins and site data of the integrated browser?",
                                isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear Browsing Data", role: .destructive) { Task { await browser.clearWebsiteData() } }
            }
        } header: {
            Text("Browser")
        } footer: {
            #if os(macOS)
            Text("Session agents can open pages, read them, click, type and take screenshots in Happier's browser, with its cookies and logins, without asking each time. This Mac serves them even when the browser window is closed.")
            #else
            Text("Session agents can open pages, read them, click, type and take screenshots in Happier's browser, with its cookies and logins, without asking each time. Here it serves them while Happier is on screen, so the pages they open show up where you are; otherwise agents use your Mac.")
            #endif
        }
    }
}
