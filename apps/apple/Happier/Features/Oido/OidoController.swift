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
        if UserDefaults.standard.bool(forKey: Key.listening) { Task { await start() } }
    }

    var isListening: Bool { state == .listening || state == .starting }

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
        let capture = OidoCapture(pipeline: pipeline, onChunks: { _ in
            Task { await uploader?.wake() }
        }, onSnapshot: { snapshot in
            Task { @MainActor [weak self] in
                self?.levelDBFS = snapshot.levelDBFS
                self?.hearingSpeech = snapshot.hearingSpeech
            }
        }, onFailure: { message in
            Task { @MainActor [weak self] in self?.captureFailed(message) }
        })
        do {
            try capture.start()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.capture = capture
        listeningSince = Date()
        state = .listening
        #if os(macOS)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Oído is listening")
        #endif
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
