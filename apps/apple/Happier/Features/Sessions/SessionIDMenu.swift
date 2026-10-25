import SwiftUI

/// The same identifiers in the session list and the conversation's information menu.
struct SessionIDMenu: View {
    let sessionId: String
    let providerName: String?
    let providerSessionId: String?

    var body: some View {
        Menu("Copy Session ID", systemImage: "doc.on.doc") {
            Button { MessageClipboard.copy(sessionId) } label: {
                Label {
                    Text("Happier")
                    Text(sessionId)
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
            }
            if let providerSessionId {
                Button { MessageClipboard.copy(providerSessionId) } label: {
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
