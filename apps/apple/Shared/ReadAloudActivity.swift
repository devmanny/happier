#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

/// The reading aloud as a Live Activity: on the Dynamic Island and the Lock Screen, so it's clear
/// Happier is the one talking while it's minimized. Shared by the app (which starts and updates it)
/// and the widget extension (which draws it).
struct ReadAloudAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The conversation being read (or "Reading aloud" for a message picked by hand).
        var title: String
        /// The start of the message being read; empty while waiting for the next one.
        var snippet: String
        var isSpeaking: Bool
        var isPaused: Bool
        /// Messages waiting their turn.
        var waiting: Int
        /// Auto read is on: new messages will keep coming.
        var autoRead: Bool
    }
}

// The Live Activity's buttons. They run in the app (`LiveActivityIntent`), which owns the reader;
// the widget extension only needs their types to draw the buttons.

struct ReadAloudTogglePauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Reading"
    func perform() async throws -> some IntentResult {
        #if HAPPIER_APP
        await MainActor.run { MessageSpeaker.shared.togglePause() }
        #endif
        return .result()
    }
}

struct ReadAloudNextIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Next Message"
    func perform() async throws -> some IntentResult {
        #if HAPPIER_APP
        await MainActor.run { MessageSpeaker.shared.nextBlock() }
        #endif
        return .result()
    }
}

struct ReadAloudStopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Reading Aloud"
    func perform() async throws -> some IntentResult {
        #if HAPPIER_APP
        await MainActor.run { MessageSpeaker.shared.stopEverything() }
        #endif
        return .result()
    }
}
#endif
