import Testing
@testable import HappierKit

/// A conversation can be open in several windows at once (Mac, iPad): closing one of them must
/// not stop the live work (pending refresh, read marks) the others still need.
struct OpenSessionsTests {
    @Test func staysOpenUntilEveryWindowClosesIt() {
        var open = OpenSessions()
        open.open("a")
        open.open("a")
        open.close("a")
        #expect(open.contains("a"))
        open.close("a")
        #expect(!open.contains("a"))
    }

    @Test func closingWhatIsNotOpenIsHarmless() {
        var open = OpenSessions()
        open.close("a")
        open.open("a")
        #expect(open.contains("a"))
        #expect(Array(open) == ["a"])
    }
}
