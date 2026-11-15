import AVFoundation
import HappierKit
import os

/// The microphone for Oído: the input converted to 16 kHz mono and fed to an `OidoPipeline` on its
/// own queue (the tap's thread must not encode or write files). Independent of dictation's engine.
final class OidoCapture: @unchecked Sendable {
    struct Snapshot: Sendable {
        var levelDBFS: Float
        var hearingSpeech: Bool
    }

    private static let log = Logger(subsystem: "dev.happier.apple", category: "oido")
    /// Everything below is touched only on this queue.
    private let queue = DispatchQueue(label: "dev.happier.oido.capture", qos: .userInitiated)
    private let pipeline: OidoPipeline
    private let onChunks: @Sendable (Int) -> Void
    private let onSnapshot: @Sendable (Snapshot) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Oido.sampleRate), channels: 1, interleaved: false)!

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samplesInStream = 0
    private var streamStart = Date()
    private var lastSnapshot = Date.distantPast
    private var configurationObserver: NSObjectProtocol?

    init(pipeline: OidoPipeline, onChunks: @escaping @Sendable (Int) -> Void,
         onSnapshot: @escaping @Sendable (Snapshot) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.pipeline = pipeline
        self.onChunks = onChunks
        self.onSnapshot = onSnapshot
        self.onFailure = onFailure
    }

    func start() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let converter = AVAudioConverter(from: format, to: target) else {
            throw OidoCaptureError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.receive(buffer)
        }
        engine.prepare()
        try engine.start()
        queue.sync {
            self.engine = engine
            self.converter = converter
            self.beginStream(at: Date())
        }
        // The input device changed (headset, another mic): start over with its format.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            Self.log.notice("audio configuration changed; restarting the microphone")
            self.stop()
            do { try self.start() } catch { self.onFailure(error.localizedDescription) }
        }
    }

    /// Stops listening; what was heard is chunked and queued.
    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        queue.sync {
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            converter = nil
            endStream()
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        // Copied before leaving the tap: the engine reuses its buffer.
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        let arrived = Date()
        queue.async { [weak self] in self?.process(copy, arrived: arrived) }
    }

    private func process(_ buffer: AVAudioPCMBuffer, arrived: Date) {
        guard let converter, let samples = convert(buffer, with: converter), !samples.isEmpty else { return }
        // The stream's clock is its sample count. Audio that stopped coming (sleep, a stalled device)
        // would put every later chunk at the wrong time: start a new stream at the real time instead.
        let duration = Double(samples.count) / Double(Oido.sampleRate)
        let expected = streamStart.addingTimeInterval(Double(samplesInStream) / Double(Oido.sampleRate) + duration)
        if abs(arrived.timeIntervalSince(expected)) > 2 {
            Self.log.notice("oido stream clock off by \(arrived.timeIntervalSince(expected), privacy: .public) s; new stream")
            endStream()
            beginStream(at: arrived.addingTimeInterval(-duration))
        }
        samplesInStream += samples.count
        do {
            let queued = try pipeline.append(samples)
            if !queued.isEmpty { onChunks(queued.count) }
        } catch {
            onFailure(error.localizedDescription)
        }
        if arrived.timeIntervalSince(lastSnapshot) >= 0.25 {
            lastSnapshot = arrived
            onSnapshot(Snapshot(levelDBFS: pipeline.levelDBFS, hearingSpeech: pipeline.hearingSpeech))
        }
    }

    private func beginStream(at date: Date) {
        streamStart = date
        samplesInStream = 0
        pipeline.begin(at: date)
    }

    private func endStream() {
        guard pipeline.isRunning else { return }
        do {
            let queued = try pipeline.end()
            if !queued.isEmpty { onChunks(queued.count) }
        } catch {
            onFailure(error.localizedDescription)
        }
        onSnapshot(Snapshot(levelDBFS: -120, hearingSpeech: false))
    }

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float]? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0] else {
            Self.log.error("oido conversion failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

enum OidoCaptureError: LocalizedError {
    case microphoneUnavailable
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: String(localized: "The microphone isn't available right now.")
        case .permissionDenied: String(localized: "Happier doesn't have access to the microphone. Allow it in System Settings › Privacy & Security › Microphone.")
        }
    }
}
