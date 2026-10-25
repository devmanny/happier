import Foundation
import Testing
@testable import HappierKit

/// Opt-in measurements of the work the conversation does per update and per scroll frame, on a
/// real session's rows (`/tmp/perf-history.json`, from `happier session history --format raw`),
/// replicated to model longer sessions. HAPPIER_PERF=1 swift test -c release --filter ChatPerf
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HAPPIER_PERF"] != nil))
struct ChatPerfTests {
    func realMessages(times: Int) throws -> [TranscriptMessage] {
        let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/perf-history.json"))
        let rows = try JSONValue.parse(data)["data"]?["messages"]?.arrayValue ?? []
        var out: [TranscriptMessage] = []
        var seq = 0
        for copy in 0..<times {
            for row in rows {
                seq += 1
                guard let raw = row["raw"], let id = row["id"]?.stringValue else { continue }
                let at = Date(timeIntervalSince1970: (row["createdAt"]?.doubleValue ?? 0) / 1000 + Double(copy) * 100_000)
                out.append(TranscriptMessage(id: "\(id)-\(copy)", seq: seq, localId: nil, createdAt: at, record: raw))
            }
        }
        return out
    }

    func median(_ runs: Int, _ work: () -> Void) -> Duration {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<runs { samples.append(clock.measure(work)) }
        return samples.sorted()[runs / 2]
    }

    @Test func perUpdateAndPerFrameCosts() throws {
        for times in [1, 8, 20] {
            let messages = try realMessages(times: times)
            var transcript = Transcript()
            transcript.apply(Array(messages.dropLast()))
            let last = messages.last!
            // A streamed message arriving: the transcript is reduced again from all its rows.
            let applyOne = median(9) { var t = transcript; t.apply([last]) }
            transcript.apply([last])
            let items = transcript.items
            // Every evaluation of the conversation's body groups all items into rows.
            let rows = median(15) { _ = ChatRow.rows(from: items, working: true) }
            // Markdown parsing of agent texts (done in MarkdownText.init, per body evaluation).
            let texts = items.compactMap { item -> String? in if case .agentText(let t) = item { t.text } else { nil } }
            let visible = Array(texts.suffix(12))
            let parseVisible = median(15) { for t in visible { _ = MarkdownSegments.parse(t) } }
            for t in visible { _ = MarkdownSegments.cached(t) }
            let cachedVisible = median(15) { for t in visible { _ = MarkdownSegments.cached(t) } }
            print("PERF markdown12 parse=\(parseVisible) cached=\(cachedVisible)")
            let attributedVisible = median(15) {
                for t in visible { _ = try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) }
            }
            print("PERF rows=\(messages.count) items=\(items.count) chatRows=\(ChatRow.rows(from: items, working: true).count) "
                  + "applyOneMessage=\(applyOne) chatRowGrouping=\(rows) markdownParse12=\(parseVisible) attributed12=\(attributedVisible)")
        }
    }

    @Test func sidebarCosts() throws {
        for count in [60, 200, 500] {
            var sessions: [Session] = []
            for i in 0..<count {
                let parent = i % 5 == 0 ? "" : "\"spawnedBySessionV1\":{\"parentSessionId\":\"s\(i - i % 5)\"},"
                let meta = "{\(parent)\"path\":\"/Users/m/Projects/p\(i % 9)\",\"machineId\":\"m\",\"summary\":{\"text\":\"Session \(i)\"}}"
                sessions.append(try Session(row: ["id": .string("s\(i)"), "seq": 1, "createdAt": 1, "updatedAt": .number(Double(1000 + i)),
                                                   "active": .bool(i % 3 == 0), "encryptionMode": "plain",
                                                   "metadata": .string(meta), "metadataVersion": 1], keys: nil))
            }
            let list = median(15) { _ = sessions.filter(\.isUserFacing).sorted { $0.sortDate > $1.sortDate } }
            let groups = median(15) { _ = SessionSidebar.groups(sessions, pinned: ["s0", "s5"]) }
            print("PERF sidebar sessions=\(count) sessionListSort=\(list) sidebarGroups=\(groups)")
        }
    }
}
