import Testing
@testable import HappierKit

/// On iPad several windows of the app are in the foreground at once; an app-wide prompt (stop
/// confirmation, error) belongs to one of them only.
struct FrontWindowTests {
    @Test func onlyTheKeyWindowAmongSeveralActiveOnesShowsAPrompt() {
        #expect(FrontWindow.showsPrompts(active: true, isKey: true, anyWindowIsKey: true))
        #expect(!FrontWindow.showsPrompts(active: true, isKey: false, anyWindowIsKey: true))
    }

    @Test func anInactiveWindowNeverShowsAPrompt() {
        #expect(!FrontWindow.showsPrompts(active: false, isKey: true, anyWindowIsKey: true))
        #expect(!FrontWindow.showsPrompts(active: false, isKey: false, anyWindowIsKey: false))
    }

    @Test func aPromptIsNotLostWhenNoWindowIsKey() {
        #expect(FrontWindow.showsPrompts(active: true, isKey: false, anyWindowIsKey: false))
    }

    /// The microphone (an Apple Pencil squeeze) opens in the one window with the focus, never in
    /// every visible window, nor in one behind.
    @Test func onlyTheFocusedWindowOpensTheMicrophone() {
        #expect(FrontWindow.takesInput(active: true, isKey: true, anyWindowIsKey: true, onlyWindow: false))
        #expect(!FrontWindow.takesInput(active: true, isKey: false, anyWindowIsKey: true, onlyWindow: false))
        #expect(!FrontWindow.takesInput(active: false, isKey: true, anyWindowIsKey: true, onlyWindow: true))
        // Before any window is touched, only a window alone on screen takes it.
        #expect(!FrontWindow.takesInput(active: true, isKey: false, anyWindowIsKey: false, onlyWindow: false))
        #expect(FrontWindow.takesInput(active: true, isKey: false, anyWindowIsKey: false, onlyWindow: true))
    }
}
