import Foundation
import Testing
@testable import HappierKit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAPPIER_PERF"] != nil))
struct PerfProbeTests {
    @Test func measureDecodeAndReduce() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["trace_0", "trace_1"] {
            let data = try Data(contentsOf: base.appending(path: "../../ui/sources/sync/__testdata__/\(name).json").standardized)
            let clock = ContinuousClock()
            var rows: [JSONValue] = []
            let parse = clock.measure { rows = (try? JSONValue.parse(data))?.arrayValue ?? [] }
            let messages = rows.map { TranscriptMessage(id: $0["id"]!.stringValue!, seq: $0["seq"]!.intValue!, localId: nil, createdAt: .now, record: $0["content"]!) }
            var t = Transcript()
            let reduceOnce = clock.measure { t.apply(messages) }
            var t2 = Transcript()
            let reduceIncremental = clock.measure { for m in messages { t2.apply([m]) } }
            let jsonFoundation = clock.measure { _ = try? JSONSerialization.jsonObject(with: data) }
            print("PERF \(name) bytes=\(data.count) rows=\(rows.count) JSONValue.parse=\(parse) JSONSerialization=\(jsonFoundation) reduceOnce=\(reduceOnce) reducePerRow=\(reduceIncremental)")
        }
    }
}
