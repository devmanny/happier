import Foundation
import Testing
@testable import HappierKit

/// Task search: every field, Meilisearch-style tolerance and ranking, highlights, closed tasks last.
@Suite struct TaskSearchTests {
    static let sep2026 = 1_789_200_000_000.0 // 2026-09-12 UTC

    static func task(_ id: String, _ title: String, _ extra: [String: JSONValue] = [:]) -> AgentTask {
        var json: [String: JSONValue] = [
            "v": 1, "id": .string(id), "title": .string(title), "status": "todo", "assignee": ["kind": "user"],
            "threads": [], "log": [], "createdAt": 0, "updatedAt": 0,
        ]
        for (key, value) in extra { json[key] = value }
        return AgentTask(json: .object(json))!
    }

    static let tasks: [AgentTask] = [
        task("zahira", "Pagarle a Zahíra la sesión de octubre"),
        task("bukis", "Recordatorio a Zahira: Bukis y piel", ["source": ["kind": "chat", "label": "WhatsApp con Zahira", "url": "https://wa.me/msg/77"]]),
        task("factura", "Enviar factura a Beyond", ["description": "La de septiembre, con el desglose de horas", "dueAt": .number(sep2026)]),
        task("growy", "Reels de matemáticas", ["directory": "/Users/manny/Projects/growy"]),
        task("eleven", "Configurar voz de Ludovico", ["log": [["at": 1, "by": ["kind": "user"], "text": "Falta el onboarding de ElevenLabs para Veta"]]]),
        task("done", "Factura de agosto", ["status": "done"]),
        task("archived", "Zahira: cambiar tarjeta", ["archivedAt": 5]),
    ]

    func search(_ query: String, _ tasks: [AgentTask] = Self.tasks) -> [TaskSearch.Result] {
        let engine = TaskSearch()
        engine.sync(tasks, context: TaskSearch.Context(timeZone: TimeZone(identifier: "UTC")!))
        return engine.search(query, in: tasks)
    }

    @Test func zahiraPagarFindsTheTaskWithBothWordsFirstWithoutAccents() {
        let ids = search("zahira pagar").map(\.id)
        #expect(ids.first == "zahira")
        #expect(ids.contains("bukis"))
        // Typos and accents don't hide it: a transposition and an accent typed the other way.
        #expect(search("zahria págar").first?.id == "zahira")
        #expect(search("ZAHÍRA").map(\.id).prefix(2).sorted() == ["bukis", "zahira"])
    }

    @Test func facturaSeptiembreMatchesTitleDescriptionAndTheDueDateAsText() {
        let results = search("factura septiembre")
        #expect(results.first?.id == "factura")
        #expect(search("facutra septimbre").first?.id == "factura")
        // "septiembre" alone matches the description and the due date (12 septiembre 2026).
        let alone = search("septiembre")
        #expect(alone.first?.id == "factura")
        #expect(alone.first?.snippet?.field == .description)
    }

    @Test func bukisGrowiAndElevenlabsOnboardingFindTheirTasksAcrossFields() {
        #expect(search("bukis").first?.id == "bukis")
        #expect(search("bukiz").first?.id == "bukis")
        // "growi": one typo away from the folder name.
        let growy = search("growi").first
        #expect(growy?.id == "growy")
        #expect(growy?.snippet?.field == .place)
        // Both words only in a comment, typed with typos and in another order.
        let eleven = search("onbording elevenlab")
        #expect(eleven.first?.id == "eleven")
        #expect(eleven.first?.snippet?.field == .comment)
        #expect(eleven.first.map { r in r.snippet!.snippet.highlights.map { String(r.snippet!.snippet.text[$0]) } } == ["onboarding", "ElevenLabs"])
    }

    @Test func theLastWordMatchesAsAPrefixWhileTyping() {
        #expect(search("fact").map(\.id).contains("factura"))
        // A finished word (followed by a space) must match whole.
        #expect(!search("fact ").map(\.id).contains("factura"))
        // Short words allow no typos.
        #expect(search("bukz").isEmpty)
    }

    @Test func titleMatchesAreHighlightedAndClosedTasksComeLastMarked() {
        let results = search("factura")
        #expect(results.map(\.id) == ["factura", "done"])
        #expect(results.last?.isClosed == true)
        let first = results[0]
        #expect(first.titleHighlights.map { String(first.task.title[$0]) } == ["factura"])
        #expect(first.snippet == nil)
        #expect(search("zahira").last?.id == "archived")
    }

    @Test func ranksTitleOverDescriptionAndCloserWordsFirst() {
        let tasks = [
            Self.task("desc", "Pendiente", ["description": "llamar a Iram"]),
            Self.task("title", "Llamar a Iram"),
            Self.task("apart", "Iram: revisar el juego y luego llamar"),
        ]
        #expect(search("iram llamar", tasks).map(\.id) == ["title", "apart", "desc"])
    }

    @Test func theIndexFollowsLiveChanges() {
        let engine = TaskSearch()
        var tasks = [Self.task("t", "Comprar boletos")]
        engine.sync(tasks, context: .init())
        #expect(engine.search("boletos", in: tasks).count == 1)
        tasks[0] = Self.task("t", "Cancelar boletos", ["updatedAt": 9])
        engine.sync(tasks, context: .init())
        #expect(engine.search("cancelar", in: tasks).count == 1)
        #expect(engine.search("comprar", in: tasks).isEmpty)
        engine.sync([], context: .init())
        #expect(engine.search("boletos", in: tasks).isEmpty)
    }

    @Test func typoBudgetFollowsWordLength() {
        func folded(_ s: String) -> [UInt32] { SearchIndex<String>.tokens(s)[0].folded }
        #expect(SearchIndex<String>.allowedTypos(4) == 0 && SearchIndex<String>.allowedTypos(5) == 1 && SearchIndex<String>.allowedTypos(9) == 2)
        #expect(SearchIndex<String>.distance(folded("factura"), folded("facutra"), limit: 1) == 1)
        #expect(SearchIndex<String>.distance(folded("septiembre"), folded("setpiembr"), limit: 2) == 2)
        #expect(SearchIndex<String>.distance(folded("septiembre"), folded("sxtxixmbre"), limit: 2) == nil)
    }

    @Test func searchesThousandsOfTasksQuickly() {
        let words = ["factura", "zahira", "reunion", "deploy", "radar", "beyond", "veta", "quantix", "growy", "iram", "pagos", "video"]
        let tasks = (0..<5000).map { i in
            Self.task("t\(i)", "\(words[i % 12]) \(words[(i / 12) % 12]) tarea \(i)",
                      ["description": .string("Detalle \(i) con \(words[(i * 7) % 12]) y notas varias número \(i * 3)")])
        }
        let engine = TaskSearch()
        let indexStart = Date()
        engine.sync(tasks, context: .init())
        let indexed = Date().timeIntervalSince(indexStart)
        let start = Date()
        let results = engine.search("factura zahria", in: tasks)
        let elapsed = Date().timeIntervalSince(start)
        print("TaskSearch 5000 tasks: index \(Int(indexed * 1000)) ms, query \(Int(elapsed * 1000)) ms, \(results.count) results")
        #expect(!results.isEmpty)
    }
}
