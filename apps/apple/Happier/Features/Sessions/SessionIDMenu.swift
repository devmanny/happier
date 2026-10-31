import HappierKit
import SwiftUI

/// The same identifiers in the session list and the conversation's information menu.
struct SessionIDMenu: View {
    let sessionId: String
    let providerName: String?
    let providerSessionId: String?
    @Environment(HappierStore.self) private var store

    var body: some View {
        if let link = SessionLink(sessionId: sessionId, server: store.server) {
            ShareLink(item: link.webURL) { Label("Share Session", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("share-session-" + sessionId)
        }
        Menu("Copy Session ID", systemImage: "doc.on.doc") {
            Button {
                MessageClipboard.copy(sessionId)
                AppHaptics.success()
            } label: {
                Label {
                    Text("Happier")
                    Text(sessionId)
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
            if let providerSessionId {
                Button {
                    MessageClipboard.copy(providerSessionId)
                    AppHaptics.success()
                } label: {
                    Label {
                        Text(providerName ?? String(localized: "Agent"))
                        Text(providerSessionId)
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }
}
