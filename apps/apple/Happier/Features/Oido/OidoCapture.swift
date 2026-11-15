import AVFoundation
import HappierKit
import os

/// Oído's ear on the app's microphone (`Microphone`, shared with dictation): the input converted
/// to 16 kHz mono and fed to an `OidoPipeline` on its own queue (the tap's thread must not encode
/// or write files). While a call or another app has the microphone, the stream ends there, so what
/// was heard is chunked and queued, and a new one starts when the audio comes back.
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
    private let onPhase: @Sendable (MicrophoneRecovery.Phase) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Oido.sampleRate), channels: 1, interleaved: false)!

    private var microphone: Microphone.Tap?
    private var stopped = false
    private var converter: AVAudioConverter?
    private var samplesInStream = 0
    private var streamStart = Date()
    private var lastSnapshot = Date.distantPast

    init(pipeline: OidoPipeline, onChunks: @escaping @Sendable (Int) -> Void, onSnapshot: @escaping @Sendable (Snapshot) -> Void,
         onPhase: @escaping @Sendable (MicrophoneRecovery.Phase) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.pipeline = pipeline
        self.onChunks = onChunks
        self.onSnapshot = onSnapshot
        self.onPhase = onPhase
        self.onFailure = onFailure
    }

    /// Starts listening. The microphone may be busy (a call): it comes to Oído once it's free, and
    /// `onPhase` says when.
    func start() async throws {
        let microphone = try await Microphone.shared.attach(.listening, onBuffer: { [weak self] buffer in
            self?.receive(buffer)
        }, onPhase: { [weak self] phase in
            self?.phaseChanged(phase)
        })
        // Paused while the microphone was coming up.
        let keep = queue.sync {
            if !stopped { self.microphone = microphone }
            return !stopped
        }
        if !keep { Microphone.shared.detach(microphone) }
    }

    /// Stops listening; what was heard is chunked and queued.
    func stop() {
        let microphone = queue.sync {
            stopped = true
            let microphone = self.microphone
            self.microphone = nil
            return microphone
        }
        if let microphone { Microphone.shared.detach(microphone) }
        queue.sync {
            converter = nil
            endStream()
        }
    }

    private func phaseChanged(_ phase: MicrophoneRecovery.Phase) {
        // After the buffers already handed over: they belong to the stream that ends here.
        if phase != .running { queue.async { [weak self] in self?.endStream() } }
        onPhase(phase)
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        // Copied before leaving the tap: the engine reuses its buffer.
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        let arrived = Date()
        queue.async { [weak self] in self?.process(copy, arrived: arrived) }
    }

    private func process(_ buffer: AVAudioPCMBuffer, arrived: Date) {
        guard !stopped else { return }
        // The input's format changes with the hardware (AirPods, another microphone).
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
        guard let converter, let samples = convert(buffer, with: converter), !samples.isEmpty else { return }
        let duration = Double(samples.count) / Double(Oido.sampleRate)
        // Back after an interruption: a new stream from now.
        if !pipeline.isRunning { beginStream(at: arrived.addingTimeInterval(-duration)) }
        // The stream's clock is its sample count. Audio that stopped coming (sleep, a stalled device)
        // would put every later chunk at the wrong time: start a new stream at the real time instead.
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
    case permissionDenied

    var errorDescription: String? {
        #if os(macOS)
        String(localized: "Happier doesn't have access to the microphone. Allow it in System Settings › Privacy & Security › Microphone.")
        #else
        String(localized: "Happier doesn't have access to the microphone. Allow it in Settings › Apps › Happier.")
        #endif
    }
}
