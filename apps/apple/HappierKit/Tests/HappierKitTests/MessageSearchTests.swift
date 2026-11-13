import Foundation
import Testing
@testable import HappierKit

private func user(_ id: String, _ text: String, seq: Int, at createdAt: Date) -> ChatItem {
    var message = UserText(id: id, text: text, createdAt: createdAt, localId: nil, isPending: false)
    message.seq = seq
    return .userText(message)
}

@Suite struct MessageSearchTests {
    @Test func requestAsksForOnePageOfMessagesAndCarriesTheCursor() {
        #expect(MessageSearch.request(query: "  relay  ", cursor: nil) == ["v": 2, "query": "relay", "limit": 20])
        #expect(MessageSearch.request(query: "relay", cursor: "o:20") == ["v": 2, "query": "relay", "limit": 20, "cursor": "o:20"])
    }

    @Test func readsAPageOfHighlightedMessages() {
        let result: JSONValue = [
            "v": 2, "ok": true, "nextCursor": "o:20",
            "coverage": ["messageCount": 1200, "sessionCount": 40, "knownSessionCount": 45, "pendingSessionCount": 3, "backfillComplete": false],
            "hits": [[
                "sessionId": "s1", "seq": 42, "createdAtMs": 1_700_000_000_000, "role": "user", "score": 7.5,
                "snippet": [["text": "Configuramos la ", "match": false], ["text": "búsqueda", "match": true]],
                "session": ["title": "Relay migration", "agent": "claude"],
            ], [
                "sessionId": "s2", "seq": 7, "createdAtMs": 1_700_000_100_000, "role": "assistant", "score": 3,
                "snippet": [["text": "otra búsqueda", "match": false]],
                "session": ["title": .null, "agent": .null],
            ]],
        ]
        guard case .page(let page) = MessageSearch.answer(result) else { Issue.record("expected a page"); return }
        #expect(page.nextCursor == "o:20")
        #expect(page.coverage == MessageSearch.Coverage(messageCount: 1200, sessionCount: 40, knownSessionCount: 45, pendingSessionCount: 3, backfillComplete: false))
        #expect(abs(page.coverage.progress - 42.0 / 45.0) < 0.0001)
        #expect(page.hits.map(\.id) == ["s1:42", "s2:7"])
        #expect(page.hits[0].fromUser)
        #expect(page.hits[0].snippet == [.init(text: "Configuramos la ", isMatch: false), .init(text: "búsqueda", isMatch: true)])
        #expect(page.hits[0].title == "Relay migration" && page.hits[0].agentFlavor == "claude")
        #expect(page.hits[0].createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(page.hits[1].title == nil && !page.hits[1].fromUser)
    }

    @Test func tellsApartOffOutdatedAndFailingMacs() {
        #expect(MessageSearch.answer(["v": 2, "ok": false, "errorCode": "memory_disabled", "error": "x"]) == .refused(.off))
        #expect(MessageSearch.answer(["v": 2, "ok": false, "errorCode": "memory_index_missing", "error": "x"]) == .refused(.off))
        // A CLI from before v2 parses the request as v1 and refuses it.
        #expect(MessageSearch.answer(["v": 1, "ok": false, "errorCode": "memory_invalid_query", "error": "x"]) == .refused(.outdated))
        #expect(MessageSearch.answer(["v": 2, "ok": false, "errorCode": "memory_failed", "error": "disk I/O error"]) == .refused(.failed("disk I/O error")))
        #expect(MessageSearch.answer("garbage") == .refused(.failed("The Mac sent an answer Happier can't read.")))
    }

    @Test func switchesSearchOnAMachineAndReadsItsStatus() {
        #expect(MessageSearch.switchRequest(enabled: true, deleteIndex: false) == ["v": 1, "enabled": true, "deleteIndex": false])
        #expect(MessageSearch.switchRequest(enabled: false, deleteIndex: true) == ["v": 1, "enabled": false, "deleteIndex": true])
        let indexing = MessageSearch.status([
            "v": 1, "enabled": true, "state": "indexing", "indexBytes": 4096,
            "coverage": ["messageCount": 120, "sessionCount": 3, "knownSessionCount": 8, "pendingSessionCount": 2, "backfillComplete": false],
        ])
        #expect(indexing?.state == .indexing && indexing?.enabled == true && indexing?.indexBytes == 4096)
        #expect(indexing?.coverage?.progress == 0.75)
        let off = MessageSearch.status(["v": 1, "enabled": false, "state": "off", "indexBytes": .null, "coverage": .null])
        #expect(off == MessageSearch.Status(enabled: false, state: .off, coverage: nil, indexBytes: nil))
        #expect(MessageSearch.status(["ok": false, "errorCode": "invalid_parameters"]) == nil)
    }

    @Test func mergesMachinesWithoutRepeatingAMessage() {
        let at = Date(timeIntervalSince1970: 10)
        func hit(_ session: String, _ seq: Int, score: Double) -> MessageSearch.Hit {
            MessageSearch.Hit(sessionId: session, seq: seq, createdAt: at, fromUser: true, snippet: [.init(text: "x", isMatch: true)],
                              score: score, title: nil, agentFlavor: nil)
        }
        let merged = MessageSearch.merge([[hit("s1", 1, score: 3), hit("s2", 4, score: 1)], [hit("s1", 1, score: 2.5), hit("s3", 2, score: 2)]])
        #expect(merged.map(\.id) == ["s1:1", "s3:2", "s2:4"])
    }

    @Test func asksForTheNewestFirstAndKeepsThemThatWayAcrossMachines() {
        // Best match first is the request every daemon already knows.
        #expect(MessageSearch.request(query: "relay", cursor: nil, order: .relevance) == ["v": 2, "query": "relay", "limit": 20])
        #expect(MessageSearch.request(query: "relay", cursor: "o:20", order: .recent)
            == ["v": 2, "query": "relay", "limit": 20, "cursor": "o:20", "order": "recent"])
        func hit(_ session: String, _ seq: Int, at: TimeInterval, score: Double) -> MessageSearch.Hit {
            MessageSearch.Hit(sessionId: session, seq: seq, createdAt: Date(timeIntervalSince1970: at), fromUser: true,
                              snippet: [.init(text: "x", isMatch: true)], score: score, title: nil, agentFlavor: nil)
        }
        let pages = [[hit("s1", 1, at: 10, score: 9), hit("s2", 4, at: 30, score: 1)], [hit("s3", 2, at: 20, score: 5), hit("s1", 1, at: 10, score: 2)]]
        #expect(MessageSearch.merge(pages, order: .recent).map(\.id) == ["s2:4", "s3:2", "s1:1"])
        #expect(MessageSearch.merge(pages, order: .relevance).map(\.id) == ["s1:1", "s3:2", "s2:4"])
    }

    @Test func groupsWhatWasFoundByDayNewestDayFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
        func hit(_ seq: Int, _ day: Int, _ hour: Int) -> MessageSearch.Hit {
            let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
            return MessageSearch.Hit(sessionId: "s", seq: seq, createdAt: date, fromUser: false, snippet: [.init(text: "x", isMatch: true)],
                                     score: 1, title: nil, agentFlavor: nil)
        }
        // Late on the 11th and early on the 12th are different days, whatever the hours between them.
        let days = MessageSearch.days([hit(1, 12, 9), hit(2, 10, 8), hit(3, 12, 1), hit(4, 11, 23)], calendar: calendar)
        #expect(days.map { calendar.component(.day, from: $0.date) } == [12, 11, 10])
        #expect(days.map { $0.hits.map(\.seq) } == [[1, 3], [4], [2]])
        #expect(MessageSearch.days([], calendar: calendar).isEmpty)
    }

    @Test func findsTheRowThatShowsAMessage() {
        let created = Date(timeIntervalSince1970: 1)
        let items: [ChatItem] = [
            user("u1", "question", seq: 3, at: created),
            .agentText(AgentText(id: "m4:0", seq: 4, text: "thinking", isThinking: true, createdAt: created)),
            .agentText(AgentText(id: "m5:0", seq: 5, text: "answer", isThinking: false, createdAt: created)),
            .agentText(AgentText(id: "m5:1", seq: 5, text: "more", isThinking: false, createdAt: created)),
            user("u7", "next question", seq: 7, at: created),
        ]
        let rows = ChatRow.rows(from: items, working: false)
        #expect(ChatRow.rowId(showingSeq: 3, in: rows) == "u1")
        #expect(ChatRow.rowId(showingSeq: 5, in: rows) == "m5:0")
        #expect(ChatRow.rowId(showingSeq: 4, in: rows) == "work:m4:0")
        // Seq 6 is indexed text this app doesn't draw: the closest drawn message before it.
        #expect(ChatRow.rowId(showingSeq: 6, in: rows) == "m5:0")
        // Older than every loaded row: that page isn't loaded yet.
        #expect(ChatRow.rowId(showingSeq: 2, in: rows) == nil)
    }

    @Test func searchesWhatIsAlreadyOnTheDeviceWhenTheMacIsAway() {
        let created = Date(timeIntervalSince1970: 100)
        let transcripts: [(sessionId: String, items: [ChatItem])] = [
            ("s1", [
                user("u1", "¿Cómo va la MIGRACIÓN del relay?", seq: 3, at: created),
                .agentText(AgentText(id: "m4", seq: 4, text: "pensando en la migracion", isThinking: true, createdAt: created)),
            ]),
            ("s2", [.agentText(AgentText(id: "m9", seq: 9, text: "Sin relación", isThinking: false, createdAt: created))]),
        ]
        let hits = MessageSearch.localHits(query: "migracion", transcripts: transcripts, limit: 10)
        #expect(hits.map(\.id) == ["s1:3"])
        #expect(hits[0].snippet.filter(\.isMatch).map(\.text) == ["MIGRACIÓN"])
        #expect(hits[0].snippet.map(\.text).joined() == "¿Cómo va la MIGRACIÓN del relay?")
    }
}
