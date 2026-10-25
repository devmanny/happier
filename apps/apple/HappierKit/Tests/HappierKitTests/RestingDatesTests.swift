import Foundation
import Testing
@testable import HappierKit

/// Sessions working at once kept overtaking each other in the list with every message; while one
/// works it keeps its place, and takes its new place once it has finished.
@MainActor
@Suite struct RestingDatesTests {
    private func session(_ id: String, activity: Double, working: Bool, now: Double) throws -> Session {
        var s = try Session(row: ["id": .string(id), "seq": 1, "createdAt": 1, "updatedAt": 1, "active": true, "encryptionMode": "plain"], keys: nil)
        s.meaningfulActivityAt = Date(timeIntervalSince1970: activity)
        s.thinking = working
        s.activeAt = Date(timeIntervalSince1970: now)
        return s
    }

    @Test func aWorkingSessionKeepsItsPlaceUntilItFinishes() throws {
        var dates = RestingDates()
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(dates.date(for: try session("a", activity: 100, working: false, now: 1_000), now: now) == Date(timeIntervalSince1970: 100))
        // Working: new messages don't move it.
        #expect(dates.date(for: try session("a", activity: 900, working: true, now: 1_000), now: now) == Date(timeIntervalSince1970: 100))
        #expect(dates.date(for: try session("a", activity: 950, working: true, now: 1_000), now: now) == Date(timeIntervalSince1970: 100))
        // Done: it moves once, to its last activity.
        #expect(dates.date(for: try session("a", activity: 960, working: false, now: 1_000), now: now) == Date(timeIntervalSince1970: 960))
        // A session first seen already working sits at its activity then.
        #expect(dates.date(for: try session("b", activity: 500, working: true, now: 1_000), now: now) == Date(timeIntervalSince1970: 500))
        #expect(dates.date(for: try session("b", activity: 990, working: true, now: 1_000), now: now) == Date(timeIntervalSince1970: 500))
    }
}
