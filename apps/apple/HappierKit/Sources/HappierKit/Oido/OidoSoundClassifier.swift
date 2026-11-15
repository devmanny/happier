#if canImport(SoundAnalysis) && !os(watchOS)
import AVFoundation
import os
import SoundAnalysis

/// Apple's built-in sound classifier (`SNClassifierIdentifier.version1`), its "speech" label as
/// the speech confidence. Runs on the device, no permission beyond the microphone's.
public final class OidoSoundClassifier: OidoSpeechClassifier {
    private let analyzer: SNAudioStreamAnalyzer
    private let format: AVAudioFormat
    private let observer = Observer()

    public init() throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Oido.sampleRate), channels: 1, interleaved: false)!
        analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        try analyzer.add(request, withObserver: observer)
    }

    public func analyze(_ samples: [Float], at position: Int) -> [OidoSpeechWindow] {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(position))
        return observer.take()
    }

    public func finish() -> [OidoSpeechWindow] {
        analyzer.completeAnalysis()
        return observer.take()
    }

    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let windows = OSAllocatedUnfairLock(initialState: [OidoSpeechWindow]())

        func take() -> [OidoSpeechWindow] {
            windows.withLock { taken in defer { taken.removeAll() }; return taken }
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let rate = Double(Oido.sampleRate)
            let start = Int((result.timeRange.start.seconds * rate).rounded())
            let end = Int((result.timeRange.end.seconds * rate).rounded())
            let confidence = Float(result.classification(forIdentifier: "speech")?.confidence ?? 0)
            windows.withLock { $0.append(OidoSpeechWindow(start: start, end: end, confidence: confidence)) }
        }
    }
}
#endif
