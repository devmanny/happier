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

    @Test func afterSendingOnlyWhatIsSaidNextIsTyped() {
        // Dictating on while sending: the field empties, the take goes on. What was typed went
        // with the message; Whisper revising its last words must not type them again.
        var sync = KeyboardTextSync()
        var field = ""
        apply(sync.edit(take: 1, text: "Te mando el mensaje en el siguiente", before: field), to: &field)
        field = ""   // sent
        apply(sync.edit(take: 1, text: "Te mando el mensaje en el siguiente turno", before: field), to: &field)
        #expect(field == "turno")
        apply(sync.edit(take: 1, text: "Te mando el mensaje en el siguiente turno. Otra cosa, ya ves", before: field), to: &field)
        #expect(field == "turno. Otra cosa, ya ves")
    }

    @Test func aRevisionOfTheSentWordsIsNotTypedAgain() {
        var sync = KeyboardTextSync()
        var field = ""
        apply(sync.edit(take: 1, text: "no sé cómo le llames", before: field), to: &field)
        field = ""
        // Whisper changed the sent words and closed the sentence: nothing new was said.
        #expect(sync.edit(take: 1, text: "No sé cómo le llamas.", before: field).isEmpty)
        // A word that grew ("turno" → "turnos") isn't typed half.
        apply(sync.edit(take: 1, text: "No sé cómo le llamas. Pasó de nuevo", before: field), to: &field)
        #expect(field == "Pasó de nuevo")
        // And a second message works the same.
        field = ""
        apply(sync.edit(take: 1, text: "No sé cómo le llamas. Pasó de nuevo, así que no es aislado", before: field), to: &field)
        #expect(field == "así que no es aislado")
        var grown = KeyboardTextSync()
        var other = ""
        apply(grown.edit(take: 2, text: "en el siguiente turno", before: other), to: &other)
        other = ""
        apply(grown.edit(take: 2, text: "en el siguiente turnos y más", before: other), to: &other)
        #expect(other == "y más")
    }

    @Test func aFieldThatReportsNothingIsNotTakenAsSent() {
        var sync = KeyboardTextSync()
        _ = sync.edit(take: 1, text: "hola", before: "")
        #expect(sync.edit(take: 1, text: "hola mundo", before: nil) == .init(delete: 0, insert: " mundo"))
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

    @Test func aTakeCountsAsListeningOnlyWhileTheAppIsAlive() {
        // iOS killed Happier mid-take: the shared status still says recording. The keyboard showed
        // a red button that heard nothing until tapped off and on.
        let now = Date(timeIntervalSince1970: 1_000_000)
        var status = DictationKeyboard.Status(phase: .recording, take: 3, standbyUntil: now.addingTimeInterval(120), heartbeat: now.addingTimeInterval(-10))
        #expect(status.isListening(at: now))
        status.heartbeat = now.addingTimeInterval(-60)
        #expect(!status.isListening(at: now))
        status = DictationKeyboard.Status(phase: .ready, standbyUntil: now.addingTimeInterval(120), heartbeat: now)
        #expect(!status.isListening(at: now))
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

    @Test func aMessageSentMidTakeEndsItAndTheNextWordsStartClean() {
        var typing = KeyboardTyping()
        _ = typing.edit(for: status(1, "x", final: true), before: "")
        #expect(typing.edit(for: status(2, "Si necesitas que inicie sesión"), before: "") == .init(delete: 0, insert: "Si necesitas que inicie sesión"))
        // Sent: the field is empty. The take is done; the app starts take 3.
        let sent = typing.messageSent(take: 2)
        #expect(sent)
        let again = typing.messageSent(take: 2)
        #expect(!again)
        // Whisper revising the sent words, with the next ones after a pause, types nothing more of
        // take 2: not the sent words again, nor ". Es esa".
        #expect(typing.edit(for: status(2, "Si necesitas que inicies sesión. Es esa"), before: "") == nil)
        #expect(typing.edit(for: status(3, "Es esa"), before: "") == .init(delete: 0, insert: "Es esa"))
    }

    @Test func aTakeThatTypedNothingYetIsNotEndedByAnEmptyField() {
        var typing = KeyboardTyping()
        _ = typing.edit(for: status(1, "x", final: true), before: "")
        _ = typing.edit(for: status(2, ""), before: "")
        let sent = typing.messageSent(take: 2)
        #expect(!sent)
    }

    @Test func aTakeNeverOpensWithPunctuation() {
        var typing = KeyboardTyping()
        _ = typing.edit(for: status(1, "x", final: true), before: "")
        #expect(typing.edit(for: status(2, ". Es esa"), before: "") == .init(delete: 0, insert: "Es esa"))
        #expect(typing.edit(for: status(3, ", y luego."), before: "") == .init(delete: 0, insert: "y luego"))
    }

    @Test func itKnowsATakeItLeftIsNotOneItTypes() {
        // Back in the field with the app still recording a take the keyboard left: the red button
        // would listen and type nothing. The keyboard ends that take and starts a new one.
        var typing = KeyboardTyping()
        _ = typing.edit(for: status(1, "x", final: true), before: "")
        _ = typing.edit(for: status(2, "hola"), before: "")
        #expect(!typing.hasLeft(take: 2))
        typing.leave(take: 2)
        #expect(typing.hasLeft(take: 2))
        #expect(!typing.hasLeft(take: 3))
        #expect(!KeyboardTyping().hasLeft(take: 5))
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

/// Tapping the microphone with it off opens Happier to turn it on; back in the app you were typing
/// in, the take starts by itself: the tap already asked for it.
@Suite struct KeyboardAutoStartTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func starts(_ start: inout KeyboardAutoStart, after seconds: TimeInterval, on: Bool = true, listening: Bool = false) -> Bool {
        start.shouldStart(at: now.addingTimeInterval(seconds), microphoneOn: on, listening: listening)
    }

    @Test func theTakeStartsOnceTheMicrophoneIsOnWhenYouComeBack() {
        var start = KeyboardAutoStart()
        start.opened(at: now)
        let turningOn = starts(&start, after: 3, on: false)
        let on = starts(&start, after: 8)
        let again = starts(&start, after: 9)
        #expect(!turningOn)
        #expect(on)
        #expect(!again)
    }

    @Test func aTapLongAgoStartsNothing() {
        var start = KeyboardAutoStart()
        start.opened(at: now)
        let late = starts(&start, after: 180)
        #expect(!late)
        #expect(start.requested == nil)
    }

    @Test func aTakeAlreadyListeningOrAStopCancelsIt() {
        var listening = KeyboardAutoStart()
        listening.opened(at: now)
        let whileListening = starts(&listening, after: 5, listening: true)
        #expect(!whileListening)
        #expect(listening.requested == nil)
        var cancelled = KeyboardAutoStart()
        cancelled.opened(at: now)
        cancelled.cancel()
        let afterCancel = starts(&cancelled, after: 5)
        #expect(!afterCancel)
    }

    @Test func aLeftTakeIsWaitedOutThenANewOneStarts() {
        var start = KeyboardAutoStart()
        start.opened(at: now, waitingOut: 7)
        // Take 7 is finishing: wait.
        let finishing = start.shouldStart(at: now.addingTimeInterval(1), microphoneOn: true, listening: true, take: 7)
        #expect(!finishing)
        #expect(start.requested != nil)
        let done = start.shouldStart(at: now.addingTimeInterval(2), microphoneOn: true, listening: false, take: 7)
        #expect(done)
        // Another take listening (the user tapped) settles it.
        var tapped = KeyboardAutoStart()
        tapped.opened(at: now, waitingOut: 7)
        let other = tapped.shouldStart(at: now.addingTimeInterval(1), microphoneOn: true, listening: true, take: 8)
        #expect(!other)
        #expect(tapped.requested == nil)
    }

    @Test func itSurvivesTheKeyboardBeingReloaded() throws {
        var start = KeyboardAutoStart()
        start.opened(at: now)
        var reloaded = try JSONDecoder().decode(KeyboardAutoStart.self, from: JSONEncoder().encode(start))
        let started = starts(&reloaded, after: 5)
        #expect(started)
    }
}
