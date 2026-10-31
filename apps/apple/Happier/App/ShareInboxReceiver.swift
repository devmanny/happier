import HappierKit
import SwiftUI
import UniformTypeIdentifiers

/// Sends what was shared to Happier from another app (Voice Memos, Photos, Files): the share
/// extension left the files and a message for a conversation in the App Group; this opens that
/// conversation and sends them like a message typed there, so progress, retry and delete apply.
struct ShareInboxReceiver: View {
    /// Bumped when the share extension opens the app.
    let requests: Int
    @Environment(HappierStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: "\(requests)|\(store.hasLoadedSessions)|\(scenePhase == .active)") {
                guard store.hasLoadedSessions, scenePhase == .active else { return }
                await deliver()
            }
    }

    private func deliver() async {
        guard let outbox = ShareOutbox.shared else { return }
        for delivery in outbox.pending() {
            let drafts = delivery.files.compactMap { url -> AttachmentDraft? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return AttachmentDraft(name: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, data: data)
            }
            // Taken before sending: a failed send stays in the conversation with Retry and Delete,
            // never sent twice from here.
            outbox.remove(delivery)
            guard !drafts.isEmpty || !delivery.message.isEmpty else { continue }
            guard store.sessions[delivery.sessionId] != nil else {
                store.lastError = String(localized: "What you shared couldn't be sent: that conversation is no longer available.")
                continue
            }
            store.openRequest = delivery.sessionId
            AppHaptics.confirm()
            await store.send(delivery.message, attachments: drafts, to: delivery.sessionId)
        }
    }
}
