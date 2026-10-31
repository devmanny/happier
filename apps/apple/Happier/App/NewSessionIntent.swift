import AppIntents
import HappierKit

/// "New session in Happier": Siri, Shortcuts and the Action button start a session from a sentence,
/// where the new-session screen last did.
struct NewHappierSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "New Session"
    static let description = IntentDescription("Starts a new Happier session with your usual agent, machine and folder.")
    static let openAppWhenRun = false

    @Parameter(title: "Task", requestValueDialog: "What should we work on?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Start a session: \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = AppDelegate.current?.store else { throw NewSessionError.notReady }
        switch await QuickSessionStart.start(text, store: store) {
        case .done: return .result(dialog: "Started. The agent is on it.")
        case .failed(let reason): throw NewSessionError.failed(reason)
        }
    }
}

enum NewSessionError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Open Happier first."
        case .failed(let reason): "\(reason)"
        }
    }
}

struct HappierShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewHappierSessionIntent(),
                    phrases: ["New session in \(.applicationName)", "Start a \(.applicationName) session", "Ask \(.applicationName) to work on something"],
                    shortTitle: "New Session", systemImageName: "plus.bubble.fill")
    }
}
