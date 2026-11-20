import AVFoundation
import XCTest
@testable import Happier
@testable import HappierKit

@MainActor
final class MessageSpeakerRecordingTests: XCTestCase {
    private let sessionId = "recording-qa"

    private func agent(_ id: String, _ text: String) -> ChatItem {
        .agentText(AgentText(id: id, text: text, isThinking: false, createdAt: .now))
    }

    func testCancelledTapDoesNotStartRecordingAfterComposerCloses() async {
        let speaker = MessageSpeaker.shared
        let store = HappierStore(server: URL(string: "https://example.invalid")!)
        let dictation = Dictation()
        speaker.stopEverything()
        defer { dictation.stop(); speaker.stopEverything() }
        speaker.toggleAutoRead(sessionId, store: store)
        dictation.toggle(prefix: "") { _ in XCTFail("A cancelled take must not transcribe") }
        dictation.stop()
        await Task.yield()
        XCTAssertFalse(dictation.isRecording)
        speaker.feed(sessionId, items: [agent("new", "Sigue leyendo.")], turnActive: false)
        XCTAssertEqual(speaker.queue.current?.id, "new")
        XCTAssertEqual(speaker.speakingText, "Sigue leyendo.")
    }

    func testRecordingStopsBacklogWithoutTakingAudioFromTheMicrophone() throws {
        let speaker = MessageSpeaker.shared
        let store = HappierStore(server: URL(string: "https://example.invalid")!)
        let recorder = NSObject()
        speaker.stopEverything()
        defer { speaker.endRecording(recorder); speaker.stopEverything() }
        speaker.toggleAutoRead(sessionId, store: store)
        let old = agent("old", "Respuesta anterior.")
        speaker.feed(sessionId, items: [old], turnActive: false)
        XCTAssertEqual(speaker.queue.current?.id, "old")

        speaker.beginRecording(recorder)
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .default)
        try audio.setActive(true)
        let during = agent("during", "Llegó mientras grababas.")
        speaker.feed(sessionId, items: [old, during], turnActive: false)
        speaker.toggle("Lectura manual durante la grabación.")
        speaker.appMovedToBackground(true)
        XCTAssertNil(speaker.speakingText)
        XCTAssertNil(speaker.queue.current)
        XCTAssertEqual(audio.category, .playAndRecord)

        speaker.appMovedToBackground(false)
        try audio.setActive(false)
        speaker.endRecording(recorder)
        speaker.feed(sessionId, items: [old, during, agent("new", "Respuesta nueva.")], turnActive: false)
        XCTAssertEqual(speaker.queue.current?.id, "new")
        XCTAssertEqual(speaker.speakingText, "Respuesta nueva.")
        XCTAssertEqual(speaker.queue.waiting, 0)
        XCTAssertEqual(audio.category, .playback)
    }

    func testOneComposerCannotReleaseAnotherRecordersSuspension() {
        let speaker = MessageSpeaker.shared
        let store = HappierStore(server: URL(string: "https://example.invalid")!)
        let first = NSObject(), second = NSObject()
        speaker.stopEverything()
        defer { speaker.endRecording(first); speaker.endRecording(second); speaker.stopEverything() }
        speaker.toggleAutoRead(sessionId, store: store)
        speaker.beginRecording(first)
        speaker.beginRecording(second)
        speaker.endRecording(first)
        speaker.endRecording(first)
        let during = agent("during", "Todavía grabando.")
        speaker.feed(sessionId, items: [during], turnActive: false)
        XCTAssertNil(speaker.speakingText)
        speaker.endRecording(second)
        speaker.feed(sessionId, items: [during, agent("new", "Ya puedes escuchar.")], turnActive: false)
        XCTAssertEqual(speaker.queue.current?.id, "new")
    }

    func testEndingRecordingSkipsStoreMessagesBeforeTheirObservationCallbackRuns() {
        let speaker = MessageSpeaker.shared
        let store = HappierStore(server: URL(string: "https://example.invalid")!)
        let recorder = NSObject()
        speaker.stopEverything()
        defer { speaker.endRecording(recorder); speaker.stopEverything() }
        speaker.toggleAutoRead(sessionId, store: store)
        speaker.beginRecording(recorder)
        var transcript = Transcript()
        transcript.apply([TranscriptMessage(id: "late", seq: 1, localId: nil, createdAt: .now,
            record: ["role": "agent", "content": ["type": "codex", "data": ["type": "message", "message": "Respuesta atrasada."]]])])
        store.transcripts[sessionId] = transcript
        speaker.endRecording(recorder)
        speaker.feed(sessionId, items: transcript.items + [agent("new", "Respuesta actual.")], turnActive: false)
        XCTAssertEqual(speaker.queue.current?.id, "new")
        XCTAssertEqual(speaker.queue.waiting, 0)
    }
}
