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
}
