import Foundation

/// Audio in (16 kHz mono, any slice size), queued chunks out: classifier → frame scorer → speech
/// gate → chunk builder → spool. One stream runs from `begin` to `end` (a microphone session, or
/// one file); its clock is the sample count, so chunk times don't drift with a busy thread.
/// Not thread-safe: feed it from one queue.
public final class OidoPipeline {
    public struct Settings: Sendable, Equatable {
        public var deviceId: String
        public var source: String
        public var vad = OidoVADParameters()
        public var targetSpeechSeconds: Double = 180
        public var maxSpanSeconds: Double = 600
        public var flushAfterSilenceSeconds: Double = 45
        public var silenceFloorDBFS: Float = -60

        public init(deviceId: String, source: String) {
            self.deviceId = deviceId
            self.source = source
        }
    }

    public let settings: Settings
    private let spool: OidoSpool
    private let makeClassifier: () -> any OidoSpeechClassifier
    private let encode: ([Float], URL) throws -> Void

    private var classifier: (any OidoSpeechClassifier)?
    private var scorer: OidoFrameScorer
    private var segmenter: OidoSegmenter
    private var builder: OidoChunkBuilder
    private var streamStart: Date?
    private var position = 0
    private var frameBuffer: [Float] = []
    private var scoredFrames = 0

    /// For the UI: the latest frame's level and whether speech is being kept right now.
    public private(set) var levelDBFS: Float = -120
    public var hearingSpeech: Bool { segmenter.inSpeech }

    public init(settings: Settings, spool: OidoSpool, makeClassifier: @escaping () -> any OidoSpeechClassifier,
                encode: @escaping ([Float], URL) throws -> Void = OidoAudioEncoder.writeM4A) {
        self.settings = settings
        self.spool = spool
        self.makeClassifier = makeClassifier
        self.encode = encode
        scorer = OidoFrameScorer(silenceFloorDBFS: settings.silenceFloorDBFS)
        segmenter = OidoSegmenter(settings.vad)
        builder = Self.makeBuilder(settings)
    }

    private static func makeBuilder(_ s: Settings) -> OidoChunkBuilder {
        OidoChunkBuilder(deviceId: s.deviceId, source: s.source, targetSpeechSeconds: s.targetSpeechSeconds,
                         maxSpanSeconds: s.maxSpanSeconds, flushAfterSilenceSeconds: s.flushAfterSilenceSeconds)
    }

    public var isRunning: Bool { streamStart != nil }

    /// Starts a stream whose first sample was heard at `date`.
    public func begin(at date: Date) {
        streamStart = date
        position = 0
        frameBuffer = []
        scoredFrames = 0
        classifier = makeClassifier()
        scorer = OidoFrameScorer(silenceFloorDBFS: settings.silenceFloorDBFS)
        segmenter = OidoSegmenter(settings.vad)
    }

    /// Returns the manifests of the chunks this audio completed.
    @discardableResult
    public func append(_ samples: [Float]) throws -> [URL] {
        guard let classifier, !samples.isEmpty else { return [] }
        let windows = classifier.analyze(samples, at: position)
        position += samples.count
        frameBuffer += samples
        while frameBuffer.count >= Oido.frameSamples {
            let frame = Array(frameBuffer.prefix(Oido.frameSamples))
            frameBuffer.removeFirst(Oido.frameSamples)
            levelDBFS = OidoLevel.dbfs(frame)
            scorer.append(frame: frame)
        }
        return try consume(scorer.add(windows))
    }

    /// Ends the stream: everything heard is chunked and queued. `final` marks the last chunk as the
    /// end of a recording (a file), as the Python client does.
    @discardableResult
    public func end(final: Bool = false) throws -> [URL] {
        guard let classifier else { return [] }
        var urls = try consume(scorer.add(classifier.finish()))
        urls += try consume(scorer.flush())
        var chunks: [OidoChunk] = []
        for span in segmenter.finish() { chunks += builder.add(start: date(ofFrame: span.startFrame), samples: span.samples) }
        if var last = builder.flush() {
            last.final = final
            chunks.append(last)
        } else if final, var last = chunks.popLast() {
            last.final = true
            chunks.append(last)
        }
        urls += try chunks.map { try spool.put($0, encode: encode) }
        self.classifier = nil
        streamStart = nil
        return urls
    }

    private func consume(_ scored: [OidoFrameScorer.Scored]) throws -> [URL] {
        var chunks: [OidoChunk] = []
        for frame in scored {
            for span in segmenter.push(frame.samples, probability: frame.probability) {
                chunks += builder.add(start: date(ofFrame: span.startFrame), samples: span.samples)
            }
            scoredFrames += 1
            // Like the Python client: every 32 frames (≈1 s) check for a long silence, on the stream's clock.
            if scoredFrames % 32 == 0, let chunk = builder.tick(now: date(ofFrame: scoredFrames)) { chunks.append(chunk) }
        }
        return try chunks.map { try spool.put($0, encode: encode) }
    }

    private func date(ofFrame frame: Int) -> Date {
        (streamStart ?? Date()).addingTimeInterval(Double(frame) * Oido.frameSeconds)
    }
}
