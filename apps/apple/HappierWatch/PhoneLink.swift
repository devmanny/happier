import HappierKit
import os
import SwiftUI
import WatchConnectivity
import WidgetKit

/// The watch's only source: the iPhone. It keeps the last summary the phone left (saved in the
/// App Group for the complications) and sends the phone what you decide here. No account keys,
/// no relay.
@MainActor
@Observable
final class PhoneLink: NSObject {
    /// One per process: the app and its App Intents share the session with the phone.
    static let shared = PhoneLink()

    private(set) var context: WatchContext? = WatchContext.load()
    /// Sessions acted on from here, until the phone's next summary catches up.
    private(set) var handled: Set<String> = []
    var path: [String] = []

    @ObservationIgnored private let log = Logger(subsystem: "dev.happier.watch", category: "phone")

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var attention: [AttentionSnapshot.Item] { (context?.attention.items ?? []).filter { !handled.contains($0.sessionId) } }
    var working: [ActivitySnapshot.Item] { context?.activity.working ?? [] }
    var usage: [ActivitySnapshot.Usage] { context?.activity.usage ?? [] }

    func item(_ sessionId: String) -> AttentionSnapshot.Item? {
        context?.attention.items.first { $0.sessionId == sessionId }
    }

    /// Asks the phone; it wakes up to do it even in your pocket. Errors are the phone's words.
    func send(_ message: WatchMessage) async -> WatchReply {
        let session = WCSession.default
        // Activation is asynchronous; an intent may send right after launch.
        for _ in 0..<50 where WCSession.isSupported() && session.activationState != .activated {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard WCSession.isSupported(), session.activationState == .activated else {
            return .failed(String(localized: "Not connected to your iPhone."))
        }
        guard session.isReachable else {
            return .failed(String(localized: "Your iPhone isn't reachable. Keep it nearby and try again."))
        }
        let reply: WatchReply = await withCheckedContinuation { continuation in
            session.sendMessage(message.dictionary, replyHandler: { dictionary in
                continuation.resume(returning: WatchReply(dictionary: dictionary) ?? .failed(String(localized: "Update Happier on your iPhone.")))
            }, errorHandler: { error in
                continuation.resume(returning: .failed(error.localizedDescription))
            })
        }
        if case .done = reply, case .permission(let sessionId, _, _, _) = message { handled.insert(sessionId) }
        if case .done = reply, case .reply(let sessionId, _) = message { handled.insert(sessionId) }
        return reply
    }

    private func receive(_ context: WatchContext) {
        self.context = context
        handled = []
        context.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let latest = WatchContext(dictionary: session.receivedApplicationContext)
        Task { @MainActor in
            if let error { log.error("activation failed: \(String(describing: error), privacy: .public)") }
            if let latest, !latest.looksLike(context) { receive(latest) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let context = WatchContext(dictionary: applicationContext) else { return }
        Task { @MainActor in receive(context) }
    }
}
