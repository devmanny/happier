import Foundation
import Testing
@testable import HappierKit

/// An agent's memory (`packages/protocol/src/agentProfiles/agentMemory.ts`): sealed `now`, journal
/// and note records under `agent/<id>/…`, and the Obsidian export built from them.
@Suite struct AgentMemoryTests {
    static let machineKey = Data(0..<32)

    static func sealed(_ value: JSONValue) throws -> String {
        try AccountScopedBlob.seal(value, kind: .agentMemory, machineKey: machineKey)
    }

    @Test func notesRoundTripUnderTheMemoryKind() throws {
        let note = AgentMemory.Note(id: "n1", title: "Manny", markdown: "Ver [[Happier]].", updatedAt: 5)
        let sealed = try note.sealed(machineKey: Self.machineKey)
        #expect(Base64.decode(sealed)?.prefix(2) == Data([0xA1, 13]))
        #expect(AccountScopedBlob.open(sealed, kind: .agentMemory, machineKey: Self.machineKey)
            == ["v": 1, "id": "n1", "title": "Manny", "markdown": "Ver [[Happier]].", "updatedAt": 5])
        #expect(AccountScopedBlob.open(sealed, kind: .agentProfile, machineKey: Self.machineKey) == nil)
        #expect(AgentMemory.Note.key(agentId: "a1", noteId: "N1") == "agent/a1/note/n1")
    }

    @Test func aListingSplitsIntoNowJournalAndNotes() throws {
        let response: JSONValue = ["items": [
            ["key": "agent/a1/profile", "value": .string(try Self.sealed(["v": 1, "id": "a1", "name": "x"])), "version": 0],
            ["key": "agent/a1/now/s1", "value": .string(try Self.sealed(["v": 1, "sessionId": "s1", "text": "Etapa 2", "title": "Memoria", "updatedAt": 30])), "version": 4],
            ["key": "agent/a1/journal/2026-11-07/e2", "value": .string(try Self.sealed(["v": 1, "id": "e2", "sessionId": "s1", "text": "Segundo", "at": 20])), "version": 0],
            ["key": "agent/a1/journal/2026-11-06/e1", "value": .string(try Self.sealed(["v": 1, "id": "e1", "text": "Primero", "at": 10])), "version": 0],
            ["key": "agent/a1/journal/2026-11-07/gone", "value": "", "version": 1],
            ["key": "agent/a1/note/n1", "value": .string(try Self.sealed(["v": 1, "id": "n1", "title": "Manny", "markdown": "Hola", "updatedAt": 9])), "version": 2],
            ["key": "agent/a1/note/bad", "value": "bm90IHNlYWxlZA==", "version": 1],
        ]]
        let memory = AgentMemory(fromList: response, machineKey: Self.machineKey)
        #expect(memory.now.map(\.sessionId) == ["s1"])
        #expect(memory.now.first?.title == "Memoria")
        // Newest first; the day comes from the key.
        #expect(memory.journal.map(\.id) == ["e2", "e1"])
        #expect(memory.journal.map(\.day) == ["2026-11-07", "2026-11-06"])
        #expect(memory.journal.first?.version == 0)
        #expect(memory.notes.map(\.id) == ["n1"])
        #expect(memory.notes.first?.version == 2)
    }

    @Test func obsidianExportKeepsLinksAndGivesEveryNoteItsOwnFile() throws {
        let utc = TimeZone(identifier: "UTC")!
        let memory = AgentMemory(
            now: [.init(sessionId: "s1", text: "Etapa 2", title: "Memoria", directory: "~/Projects/Happier", host: "Mac mini", updatedAt: 0)],
            journal: [
                .init(id: "e2", day: "2026-11-07", sessionId: "s1", text: "Subí el build", at: 1_794_000_000_000, version: 0),
                .init(id: "e1", day: "2026-11-07", sessionId: nil, text: "Empecé", at: 1_793_990_000_000, version: 0),
            ],
            notes: [
                .init(id: "n1", title: "Manny", markdown: "Ver [[Happier]].", updatedAt: 1),
                .init(id: "n2", title: "Manny", markdown: "Otra", updatedAt: 2),
                .init(id: "n3", title: "a/b: c?", markdown: "x", updatedAt: 3),
                .init(id: "n4", title: "  ", markdown: "sin título", updatedAt: 4),
            ])
        let files = AgentMemoryExport.files(agentName: "Julián", memory: memory, timeZone: utc)
        #expect(files["Notes/Manny.md"] == "Ver [[Happier]].")
        #expect(files["Notes/Manny 2.md"] == "Otra")
        #expect(files["Notes/a-b- c-.md"] == "x")
        #expect(files["Notes/Untitled.md"] == "sin título")
        #expect(files["Journal/2026-11-07.md"] == "# 2026-11-07\n\n- 18:33 Empecé\n- 21:20 Subí el build\n")
        #expect(files["Now.md"]?.contains("Etapa 2") == true)
        #expect(AgentMemoryExport.folderName(agentName: "Julián") == "Julián Memory")
    }
}
