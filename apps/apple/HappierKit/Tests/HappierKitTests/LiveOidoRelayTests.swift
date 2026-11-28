@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import HappierKit

/// Opt-in: a recording goes through Oído's capture pipeline and the real relay to a machine's
/// daemon, which writes it into the inbox folder the `oido` server reads. Nothing is stored in
/// the Keychain; the account's credentials come from a file.
///
///     HAPPIER_LIVE_SERVER=https://happier.nomada.cloud \
///     OIDO_LIVE_ACCESS_KEY=<credentials JSON: {token, encryption}> \
///     OIDO_LIVE_MACHINE=<machine id> OIDO_LIVE_INBOX=<folder on that machine> \
///     OIDO_LIVE_AUDIO=<recording> swift test --filter LiveOidoRelayTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OIDO_LIVE_AUDIO"] != nil))
struct LiveOidoRelayTests {
    @Test func aRecordingReachesTheMachinesInboxThroughTheRelay() async throws {
        let env = ProcessInfo.processInfo.environment
        let server = try #require(env["HAPPIER_LIVE_SERVER"].flatMap(URL.init(string:)))
        let machineId = try #require(env["OIDO_LIVE_MACHINE"])
        let inbox = try #require(env["OIDO_LIVE_INBOX"])
        let credentials = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: URL(filePath: try #require(env["OIDO_LIVE_ACCESS_KEY"]))))
        let samples = try Self.decode16kMono(URL(filePath: try #require(env["OIDO_LIVE_AUDIO"])))

        // Capture: Apple's classifier, the speech gate, chunks closed after 5 s of silence.
        let spoolDir = FileManager.default.temporaryDirectory.appending(path: "oido-live-\(UUID().uuidString)")
        let spool = try OidoSpool(directory: spoolDir)
        var settings = OidoPipeline.Settings(deviceId: env["OIDO_LIVE_DEVICE"] ?? "happier-e2e", source: "happier-e2e")
        settings.flushAfterSilenceSeconds = 5
        let pipeline = OidoPipeline(settings: settings, spool: spool, makeClassifier: { try! OidoSoundClassifier() })
        let start = Date()
        pipeline.begin(at: start)
        var rest = samples[...]
        while !rest.isEmpty {
            try pipeline.append(Array(rest.prefix(4_096)))
            rest = rest.dropFirst(4_096)
        }
        try pipeline.end(final: true)
        let queued = try spool.pending().map { try spool.manifest(at: $0) }
        print("oido live: \(queued.count) chunk(s): " + queued.map { "\($0.clientChunkId) \($0.durationS)s \($0.speechMap.count) span(s)" }.joined(separator: ", "))
        #expect(!queued.isEmpty)

        // Upload: the relay socket and the machine's key, as the app's store does.
        let api = HappierAPI(server: server, token: credentials.token)
        let row = try #require(try await api.machine(id: machineId))
        let machine = try Machine(row: row, keys: try credentials.accountKeys())
        let socket = SocketIOClient(serverURL: server, path: "/v1/updates",
                                    auth: ["token": .string(credentials.token), "clientType": "user-scoped"])
        try await socket.connect()
        let transport = OidoRelayTransport { method, params in
            try await MachineRPCCall.call(machine, method: method, params: params, timeout: .seconds(30)) { name, payload, timeout in
                try await socket.emitWithAck(name, payload, timeout: timeout)
            }
        }
        let uploader = OidoUploader(spool: spool, remoteDirectory: inbox, transport: transport)
        let began = Date()
        let delivered = await uploader.drainOnce()
        await socket.disconnect()
        print("oido live: uploaded in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
        #expect(delivered)
        #expect(spool.count == 0)
    }

    static func decode16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Oido.sampleRate), channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: target))
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 1024)!
        var fed = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
