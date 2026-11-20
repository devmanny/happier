import Foundation
import Testing
@testable import HappierKit

/// What Settings › Dictation shows about the last dictation, so a slow or empty one can be told apart.
struct DictationReportTests {
    private let listening = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func firstWordsCountFromListeningToTheFirstTextShown() {
        var report = DictationReport(date: listening, engine: .whisper(.largeV3Turbo), fallback: nil)
        // Whisper's empty passes put nothing in the composer: they don't count as words.
        report.shown("", at: listening.addingTimeInterval(1))
        report.shown("Hola", at: listening.addingTimeInterval(2.5))
        report.shown("Hola, revisa", at: listening.addingTimeInterval(3.5))
        #expect(report.firstText == 2.5)
    }

    @Test func aTakeHandedToAppleReportsAppleAndWhy() {
        var report = DictationReport(date: listening, engine: .whisper(.largeV3Turbo), fallback: nil)
        report.pass(seconds: 0.8)
        report.pass(seconds: 3.1)
        report.handedOver(to: .speechTranscriber, because: .whisperTooSlow)
        #expect(report.engine == .speechTranscriber)
        #expect(report.fallback == .whisperTooSlow)
        #expect(report.whisperPasses == 2)
        #expect(report.slowestPass == 3.1)
    }

    @Test func aTakeWithoutPassesShowsHowLoudItWas() {
        // Nothing transcribed: was there speech above the room at all?
        var report = DictationReport(date: listening, engine: .whisper(.largeV3Turbo), fallback: nil)
        report.heard(frameLevels: [-64, -62, -63, -61, -60, -62, -63, -58, -57, -59])
        #expect(report.loudestLevel == -57)
        #expect(report.backgroundLevel == -63)
    }

    @Test func survivesBeingSaved() throws {
        var report = DictationReport(date: listening, engine: .speechRecognizer, fallback: .whisperNotLoaded)
        report.shown("Sí", at: listening.addingTimeInterval(0.4))
        let saved = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(DictationReport.self, from: saved) == report)
    }
}
