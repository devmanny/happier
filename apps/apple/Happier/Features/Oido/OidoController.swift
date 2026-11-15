import AVFoundation
import HappierKit
import os
import SwiftUI
#if os(macOS)
import ServiceManagement
#else
import UIKit
#endif

/// Oído: listens all day, keeps only the speech, and sends it in chunks to the Mac that
/// transcribes it (the `oido` server's inbox). The audio travels through the relay like any file
/// the app sends to a machine (end-to-end encrypted, daemon bulk transfer), so it works away from
/// the office network too. App-wide, not per session: Settings › Oído and, on the Mac, the menu bar.
@MainActor
@Observable
final class OidoController {
    enum State: Equatable {
        case paused
        case starting
        case listening
        /// On, but a call or another app has the microphone (or it isn't free yet): it comes back by itself.
        case interrupted
        case failed(String)
    }

    private static let log = Logger(subsystem: "dev.happier.apple", category: "oido")
    private enum Key {
        static let listening = "oido.listening"
        static let machineId = "oido.machineId"
        static let remoteDirectory = "oido.remoteDirectory"
        static let deviceId = "oido.deviceId"
        static let showInMenuBar = "oido.showInMenuBar"
    }

    /// Where the daemon writes the chunks: relative to the Mac mini's home folder. `oido serve`
    /// reads `<data_dir>/inbox` with `[inbox] enabled = true`.
    static let defaultRemoteDirectory = ".local/share/oido/inbox"

    private(set) var state: State = .paused
    private(set) var upload = OidoUploader.Status()
    private(set) var levelDBFS: Float = -120
    private(set) var hearingSpeech = false
    private(set) var listeningSince: Date?

    var machineId: String? {
        didSet {
            UserDefaults.standard.set(machineId, forKey: Key.machineId)
            reconfigureUploads()
        }
    }

    var remoteDirectory: String {
        didSet {
            UserDefaults.standard.set(remoteDirectory, forKey: Key.remoteDirectory)
            reconfigureUploads()
        }
    }

    /// The name the transcripts carry (`device_id`); the Python client's default for this Mac, so a
    /// switch from it keeps one timeline. Takes effect on the next start.
    var deviceId: String {
        didSet { UserDefaults.standard.set(deviceId, forKey: Key.deviceId) }
    }

    var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: Key.showInMenuBar) }
    }

    private let store: HappierStore
    private let spool: OidoSpool?
    private let uploader: OidoUploader?
    private var capture: OidoCapture?
    /// Wakes the uploader whenever the relay connection comes back (the app returning to the front).
    @ObservationIgnored private var connectionWatch: Task<Void, Never>?
    #if os(macOS)
    /// Keeps the Mac awake and out of App Nap while listening (as `caffeinate -i` did for the Python client).
    private var activity: NSObjectProtocol?
    #endif

    init(store: HappierStore) {
        self.store = store
        let defaults = UserDefaults.standard
        let directory = defaults.string(forKey: Key.remoteDirectory) ?? Self.defaultRemoteDirectory
        machineId = defaults.string(forKey: Key.machineId)
        remoteDirectory = directory
        deviceId = defaults.string(forKey: Key.deviceId) ?? Self.defaultDeviceId()
        showInMenuBar = defaults.object(forKey: Key.showInMenuBar) as? Bool ?? true
        let sink = StatusSink()
        var failure: Error?
        do {
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Oido/spool")
            let spool = try OidoSpool(directory: folder)
            self.spool = spool
            uploader = OidoUploader(spool: spool, remoteDirectory: directory, transport: nil, onStatus: { status in
                Task { @MainActor in sink.controller?.upload = status }
            })
        } catch {
            spool = nil
            uploader = nil
            failure = error
        }
        sink.controller = self
        if let failure {
            Self.log.error("oido spool unavailable: \(String(describing: failure), privacy: .public)")
            state = .failed(failure.localizedDescription)
        }
    }

    /// Hands the uploader's reports to the controller once it exists.
    private final class StatusSink: @unchecked Sendable {
        @MainActor weak var controller: OidoController?
    }

    /// At launch: send what an earlier run left queued, and listen again if it was listening.
    func resume() {
        guard let uploader else { return }
        store.restore()
        reconfigureUploads()
        Task { await uploader.start() }
        watchConnection(uploader)
        if wantsToListen { Task { await start() } }
    }

    /// Whether the user turned Oído on (kept across launches; a call or a failure doesn't change it).
    private var wantsToListen: Bool { UserDefaults.standard.bool(forKey: Key.listening) }

    /// On: listening, coming up, or waiting for the microphone to be free again.
    var isListening: Bool { state == .listening || state == .starting || state == .interrupted }

    /// Chunks that failed to send while the app was in the background (the relay connection
    /// closes there) go as soon as the connection is back, instead of at the next backoff.
    private func watchConnection(_ uploader: OidoUploader) {
        connectionWatch?.cancel()
        connectionWatch = Task { [store] in
            for await online in Observations({ @MainActor in store.connection == .online }) where online {
                await uploader.wake()
            }
        }
    }

    /// Back in front: an Oído that's on but failed (the microphone permission given meanwhile, an
    /// earlier launch in the background) tries again. The microphone itself recovers on its own.
    func appBecameActive() {
        if wantsToListen, case .failed = state { Task { await start() } }
    }

    func toggle() {
        if isListening { pause() } else { Task { await start() } }
    }

    func start() async {
        guard !isListening, let spool else { return }
        UserDefaults.standard.set(true, forKey: Key.listening)
        state = .starting
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed(OidoCaptureError.permissionDenied.localizedDescription)
            return
        }
        guard state == .starting else { return }
        #if os(macOS)
        let source = "happier-macos"
        #else
        let source = "happier-ios"
        #endif
        let pipeline = OidoPipeline(settings: .init(deviceId: deviceId, source: source), spool: spool, makeClassifier: {
            do { return try OidoSoundClassifier() } catch {
                Self.log.error("sound classifier unavailable, using loudness: \(String(describing: error), privacy: .public)")
                return OidoLoudnessClassifier()
            }
        })
        let uploader = uploader
        let sink = CaptureSink()
        sink.controller = self
        let capture = OidoCapture(pipeline: pipeline, onChunks: { _ in
            Task { await uploader?.wake() }
        }, onSnapshot: { snapshot in
            Task { @MainActor in
                guard let controller = sink.current else { return }
                controller.levelDBFS = snapshot.levelDBFS
                controller.hearingSpeech = snapshot.hearingSpeech
            }
        }, onPhase: { phase in
            Task { @MainActor in sink.current?.microphoneChanged(phase) }
        }, onFailure: { message in
            Task { @MainActor in sink.current?.captureFailed(message) }
        })
        sink.capture = capture
        // Set first: pausing while the microphone comes up stops this capture.
        self.capture = capture
        do {
            try await capture.start()
        } catch {
            guard self.capture === capture else { return }
            self.capture = nil
            state = .failed(error.localizedDescription)
            return
        }
        guard self.capture === capture else { return }
        #if os(macOS)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Oído is listening")
        #endif
    }

    /// Hands a capture's reports to the controller while it's still the current capture (a late
    /// report from one already paused changes nothing), without a cycle.
    private final class CaptureSink: @unchecked Sendable {
        @MainActor weak var controller: OidoController?
        @MainActor weak var capture: OidoCapture?

        @MainActor var current: OidoController? {
            guard let controller, let capture, controller.capture === capture else { return nil }
            return controller
        }
    }

    private func microphoneChanged(_ phase: MicrophoneRecovery.Phase) {
        switch phase {
        case .running:
            if listeningSince == nil { listeningSince = Date() }
            state = .listening
        case .starting:
            if state != .listening { state = .starting }
        case .interrupted, .waiting:
            levelDBFS = -120
            hearingSpeech = false
            state = .interrupted
        case .off:
            break
        }
    }

    func pause() {
        UserDefaults.standard.set(false, forKey: Key.listening)
        stopCapture()
        state = .paused
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        listeningSince = nil
        levelDBFS = -120
        hearingSpeech = false
        #if os(macOS)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        #endif
        Task { await uploader?.wake() }
    }

    private func captureFailed(_ message: String) {
        Self.log.error("oido capture failed: \(message, privacy: .public)")
        stopCapture()
        state = .failed(message)
    }

    /// Try sending now (the button beside a failed upload).
    func retryUploads() {
        Task { await uploader?.wake() }
    }

    private func reconfigureUploads() {
        guard let uploader else { return }
        let transport: OidoRelayTransport? = machineId.map { machineId in
            OidoRelayTransport { [store] method, params in
                try await store.machineRPC(machineId, method: method, params: params)
            }
        }
        let directory = remoteDirectory
        Task { await uploader.configure(transport: transport, remoteDirectory: directory) }
    }

    /// `oido.config.default_device_id`: the host name's first label, lowercased.
    static func defaultDeviceId() -> String {
        #if os(macOS)
        let raw = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac"
        #else
        let raw = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
        return Oido.deviceId(from: raw) ?? "mac"
    }

    // MARK: Open at login (macOS)

    #if os(macOS)
    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Self.log.error("login item: \(String(describing: error), privacy: .public)")
            }
        }
    }
    #endif
}
