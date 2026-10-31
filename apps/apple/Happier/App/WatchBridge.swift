#if os(iOS)
import HappierKit
import os
import UIKit
import WatchConnectivity

/// The iPhone's side of the Apple Watch: it leaves the watch what's waiting and what's working
/// (the same snapshots as the widgets) and does what the watch asks through the paths the
/// notification buttons and the new-session screen already use. The watch keeps no account keys.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()
    /// Set by the app delegate; nil until then (a message arriving first is refused, not lost: the
    /// watch shows the failure and the user taps again).
    var store: HappierStore?

    private let log = Logger(subsystem: "dev.happier.apple", category: "watch")
    private var lastSent: WatchContext?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Leaves the watch the latest summary when it changed; the watch gets it when it's next awake.
    func publish(_ context: WatchContext) {
        lastSent = context
        send(context)
    }

    private func send(_ context: WatchContext) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext(context.dictionary)
        } catch {
            log.error("watch context failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func handle(_ message: WatchMessage) async -> WatchReply {
        guard let store else { return .failed(String(localized: "Open Happier on your iPhone first.")) }
        // Woken for this: the work stays alive past the few seconds the system grants by default.
        let task = UIApplication.shared.beginBackgroundTask(withName: "watch-message")
        defer {
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            if UIApplication.shared.applicationState == .background { store.appDidEnterBackground() }
        }
        switch message {
        case .permission, .reply:
            guard let tap = message.pushTap else { return .failed("") }
            return await store.handle(tap) ? .done(sessionId: tap.sessionId) : .failed(String(localized: "Couldn't reach the agent."))
        case .newSession(let text):
            return await QuickSessionStart.start(text, store: store)
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error { log.error("watch activation failed: \(String(describing: error), privacy: .public)") }
            if let lastSent { send(lastSent) }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Another watch was paired: start over with it.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in if let lastSent { send(lastSent) } }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        // Decoded here so only a Sendable value crosses to the main actor; the reply closure
        // itself isn't Sendable but is only ever called once, from the task below.
        let decoded = WatchMessage(dictionary: message)
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            guard let decoded else {
                reply(WatchReply.failed(String(localized: "Update Happier on your iPhone.")).dictionary)
                return
            }
            reply(await handle(decoded).dictionary)
        }
    }
}
#endif
