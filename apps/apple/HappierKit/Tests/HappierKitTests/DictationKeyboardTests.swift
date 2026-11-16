import Foundation
import Testing
@testable import HappierKit

/// The dictation keyboard types the app's live transcript into any text field: each update deletes
/// back only to where Whisper changed its mind and types the rest.
@Suite struct DictationKeyboardTests {
    private func apply(_ edit: KeyboardTextSync.Edit, to field: inout String) {
        field.removeLast(min(edit.delete, field.count))
        field += edit.insert
    }

    @Test func revisionsReplaceOnlyTheWordsThatChanged() {
        var sync = KeyboardTextSync()
        var field = ""
        apply(sync.edit(take: 1, text: "Hola como", before: field), to: &field)
        #expect(field == "Hola como")
        let edit = sync.edit(take: 1, text: "Hola, ¿cómo estás?", before: field)
        #expect(edit.delete == 5)
        apply(edit, to: &field)
        #expect(field == "Hola, ¿cómo estás?")
    }

    @Test func aTakeAfterAWordStartsWithASpaceButNotBeforePunctuation() {
        var sync = KeyboardTextSync()
        var field = "Te escribo"
        apply(sync.edit(take: 1, text: "mañana", before: field), to: &field)
        #expect(field == "Te escribo mañana")
        apply(sync.edit(take: 2, text: ", sin falta.", before: field), to: &field)
        #expect(field == "Te escribo mañana, sin falta.")
        var fresh = KeyboardTextSync()
        var line = "Listo "
        apply(fresh.edit(take: 3, text: "Gracias", before: line), to: &line)
        #expect(line == "Listo Gracias")
    }

    @Test func anOpeningMarkStartsAWordWithASpace() {
        var sync = KeyboardTextSync()
        var field = "Te escribo"
        apply(sync.edit(take: 1, text: "¿vienes?", before: field), to: &field)
        #expect(field == "Te escribo ¿vienes?")
        var other = KeyboardTextSync()
        var exclaim = "Listo"
        apply(other.edit(take: 2, text: "¡Qué bien!", before: exclaim), to: &exclaim)
        #expect(exclaim == "Listo ¡Qué bien!")
    }

    @Test func aNewTakeNeverDeletesThePreviousOne() {
        var sync = KeyboardTextSync()
        var field = ""
        apply(sync.edit(take: 1, text: "Primero.", before: field), to: &field)
        apply(sync.edit(take: 2, text: "Segundo", before: field), to: &field)
        #expect(field == "Primero. Segundo")
    }

    @Test func afterTheUserEditsItTypesNothingMore() {
        var sync = KeyboardTextSync()
        var field = ""
        apply(sync.edit(take: 1, text: "Hola mundo", before: field), to: &field)
        // The cursor moved or the user typed: what's before it no longer ends with what was typed.
        // The user is fixing the text; anything typed now would land in the middle of it.
        #expect(sync.edit(take: 1, text: "Hola mundo entero", before: "Hola A").isEmpty)
        #expect(sync.stopped)
        #expect(sync.edit(take: 1, text: "Hola mundo entero.", before: "Hola A mundo").isEmpty)
        // The next take types again.
        #expect(sync.edit(take: 2, text: "Sí", before: "Hola A mundo") == .init(delete: 0, insert: " Sí"))
    }

    @Test func aFieldThatShowsOnlyPartOfTheTextIsTrusted() {
        var sync = KeyboardTextSync()
        _ = sync.edit(take: 1, text: "una frase bastante larga", before: "")
        // Some fields report only the last few characters before the cursor.
        let edit = sync.edit(take: 1, text: "una frase bastante largo", before: "larga")
        #expect(edit == .init(delete: 1, insert: "o"))
        #expect(!sync.stopped)
        // And some report nothing at all.
        #expect(sync.edit(take: 1, text: "una frase bastante largo.", before: nil) == .init(delete: 0, insert: "."))
    }

    @Test func theMicrophoneCountsAsOnOnlyWhileTheAppIsAliveAndInStandby() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var status = DictationKeyboard.Status(phase: .ready, standbyUntil: now.addingTimeInterval(120), heartbeat: now.addingTimeInterval(-10))
        #expect(status.microphoneOn(at: now))
        // The app was killed: its heartbeat went stale.
        status.heartbeat = now.addingTimeInterval(-60)
        #expect(!status.microphoneOn(at: now))
        // The standby ran out.
        status.heartbeat = now
        status.standbyUntil = now.addingTimeInterval(-1)
        #expect(!status.microphoneOn(at: now))
        status = DictationKeyboard.Status(phase: .off, standbyUntil: now.addingTimeInterval(120), heartbeat: now)
        #expect(!status.microphoneOn(at: now))
    }

    @Test func statusAndCommandsCrossTheSharedFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "keyboard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = DictationKeyboard.Channel(directory: folder)
        let keyboard = DictationKeyboard.Channel(directory: folder)
        let command = DictationKeyboard.Command(action: .start)
        keyboard.send(command)
        #expect(app.readCommand() == command)
        let status = DictationKeyboard.Status(phase: .recording, take: 3, text: "hola", heartbeat: .now, command: command.id)
        app.publish(status)
        #expect(keyboard.readStatus() == status)
        #expect(!DictationKeyboard.Command(action: .start, sent: .now.addingTimeInterval(-30)).isFresh())
    }
}

/// Which takes the keyboard types: every take from the first one it saw, each once, even when the
/// keyboard was reloaded in between (switching apps, the app opened to start the microphone).
@Suite struct KeyboardTypingTests {
    private func status(_ take: Int, _ text: String, final: Bool = false) -> DictationKeyboard.Status {
        DictationKeyboard.Status(phase: final ? .ready : .recording, take: take, text: text, final: final)
    }

    @Test func aTakeFinishedBeforeTheKeyboardFirstLookedIsNotTyped() {
        var typing = KeyboardTyping()
        #expect(typing.edit(for: status(4, "viejo", final: true), before: "") == nil)
        #expect(typing.edit(for: status(5, "nuevo"), before: "") == .init(delete: 0, insert: "nuevo"))
    }

    @Test func aTakeStillGoingWhenTheKeyboardCameBackIsTypedWhole() {
        var typing = KeyboardTyping()
        // Started from the app; the keyboard sees it on return, words already in.
        #expect(typing.edit(for: status(7, "ya llevo esto"), before: "") == .init(delete: 0, insert: "ya llevo esto"))
    }

    @Test func aTakeDoesNotEndWithThePeriodWhisperAdds() {
        var typing = KeyboardTyping()
        _ = typing.edit(for: status(2, "x", final: true), before: "")
        // Stopping mid-sentence: Whisper closes it with a period, which the keyboard leaves out.
        #expect(typing.edit(for: status(3, "Estoy escribiendo una frase."), before: "") == .init(delete: 0, insert: "Estoy escribiendo una frase"))
        #expect(typing.edit(for: status(3, "Estoy escribiendo una frase y luego.", final: true), before: "Estoy escribiendo una frase")
            == .init(delete: 0, insert: " y luego"))
        // Questions, exclamations, ellipses and inner periods stay.
        #expect(typing.edit(for: status(4, "Hola. ¿Vienes?", final: true), before: "") == .init(delete: 0, insert: "Hola. ¿Vienes?"))
        #expect(typing.edit(for: status(5, "Pues...", final: true), before: "") == .init(delete: 0, insert: "Pues..."))
    }

    @Test func aTakeTheUserEditedIsLeftForGood() {
        var typing = KeyboardTyping()
        _ = typing.edit(for: status(1, "x", final: true), before: "")
        #expect(typing.edit(for: status(2, "Busca una Mac"), before: "") == .init(delete: 0, insert: "Busca una Mac"))
        #expect(typing.userTookOver == nil)
        // The user tapped into a word and typed: the take stops typing, for good.
        #expect(typing.edit(for: status(2, "Busca una Mac Studio"), before: "Busca una A") == nil)
        #expect(typing.userTookOver == 2)
        #expect(typing.edit(for: status(2, "Busca una Mac Studio.", final: true), before: "Busca una A") == nil)
        #expect(typing.edit(for: status(3, "Sí."), before: "Busca una A") == .init(delete: 0, insert: " Sí"))
    }

    @Test func aTakeLeftWhenTheKeyboardClosedIsNotTypedOnReturn() {
        var typing = KeyboardTyping()
        _ = typing.edit(for: status(8, "hola"), before: "")
        // Switched to another keyboard mid-take: what was heard after that isn't typed on return.
        typing.leave(take: 8)
        #expect(typing.edit(for: status(8, "hola y otras cosas", final: true), before: "hola") == nil)
        #expect(typing.edit(for: status(9, "nuevo"), before: "hola") == .init(delete: 0, insert: " nuevo"))
    }

    @Test func eachTakeIsTypedOnceAcrossKeyboardReloads() throws {
        var typing = KeyboardTyping()
        _ = typing.edit(for: status(1, "hola"), before: "")
        // The keyboard is reloaded mid-take: it carries on from what it had typed.
        var reloaded = try JSONDecoder().decode(KeyboardTyping.self, from: JSONEncoder().encode(typing))
        #expect(reloaded.edit(for: status(1, "hola mundo", final: true), before: "hola") == .init(delete: 0, insert: " mundo"))
        // The same final status again (a second notification): nothing more.
        #expect(reloaded.edit(for: status(1, "hola mundo", final: true), before: "hola mundo") == nil)
    }
}
