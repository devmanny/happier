import Foundation
import HappierKit
import Observation

/// What Settings › Dictation shows about dictation on this device: the last take (which engine
/// wrote it and why, how long the first words took) and the Whisper model in memory. Kept across
/// launches, so a slow or empty dictation can be explained afterwards without logs.
@MainActor
@Observable
final class DictationDiagnostics {
    static let shared = DictationDiagnostics()

    private static let takeKey = "dictation.lastTake.v1"
    private static let whisperKey = "dictation.whisperStatus.v1"

    private(set) var lastTake: DictationReport?
    private(set) var whisperStatus: WhisperModelStatus

    private init() {
        let defaults = UserDefaults.standard
        lastTake = defaults.data(forKey: Self.takeKey).flatMap { try? JSONDecoder().decode(DictationReport.self, from: $0) }
        var status = defaults.data(forKey: Self.whisperKey).flatMap { try? JSONDecoder().decode(WhisperModelStatus.self, from: $0) }
            ?? WhisperModelStatus()
        // Nothing is in memory at launch; the last load's time and a failure stay.
        if status.phase != .failed {
            status.phase = .notLoaded
            status.since = nil
            status.unloaded = nil
        }
        whisperStatus = status
    }

    func save(_ take: DictationReport) {
        lastTake = take
        if let data = try? JSONEncoder().encode(take) { UserDefaults.standard.set(data, forKey: Self.takeKey) }
    }

    func whisper(_ change: (inout WhisperModelStatus) -> Void) {
        change(&whisperStatus)
        if let data = try? JSONEncoder().encode(whisperStatus) { UserDefaults.standard.set(data, forKey: Self.whisperKey) }
    }
}

/// One take's report while it runs: written by the recognizer's thread (Whisper's passes, a
/// handover) and by `Dictation` (the words shown), saved when the take ends.
final class DictationTakeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var report: DictationReport

    init(engine: DictationEngine, fallback: DictationFallback?) {
        var report = DictationReport(date: .now, engine: engine, fallback: fallback)
        report.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        report.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        self.report = report
    }

    var current: DictationReport { lock.withLock { report } }

    /// The microphone is up: the first words count from now.
    func listening() { lock.withLock { report.date = .now } }
    func shown(_ text: String) { lock.withLock { report.shown(text, at: .now) } }
    func pass(seconds: TimeInterval) { lock.withLock { report.pass(seconds: seconds) } }
    func heard(frameLevels: [Float]) { lock.withLock { report.heard(frameLevels: frameLevels) } }
    func handedOver(to engine: DictationEngine, because reason: DictationFallback) {
        lock.withLock { report.handedOver(to: engine, because: reason) }
    }
}
