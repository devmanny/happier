import Testing
@testable import HappierKit

/// Auto read stops by itself in the background after 10 minutes with nothing to read, so the
/// silent keep-alive and the open socket don't run for hours.
@Suite struct AutoReadIdleTests {
    @Test func pausesTenMinutesAfterTheLastThingToReadInTheBackground() {
        var idle = AutoReadIdle()
        idle.note(.init(reading: false, waiting: 0, turnActive: false, inBackground: true), at: 0)
        #expect(idle.deadline == 600)
        #expect(!idle.shouldPause(at: 599))
        #expect(idle.shouldPause(at: 600))
    }

    @Test func readingQueuedMessagesOrAWorkingAgentIsNotIdle() {
        var idle = AutoReadIdle()
        idle.note(.init(reading: true, waiting: 0, turnActive: false, inBackground: true), at: 0)
        #expect(idle.deadline == nil)
        idle.note(.init(reading: false, waiting: 2, turnActive: false, inBackground: true), at: 10)
        #expect(idle.deadline == nil)
        // The agent is still working on the reply: something is coming.
        idle.note(.init(reading: false, waiting: 0, turnActive: true, inBackground: true), at: 20)
        #expect(idle.deadline == nil)
        // Idle counts from when the last reading or turn ended, not from when it was first noticed.
        idle.note(.init(reading: false, waiting: 0, turnActive: false, inBackground: true), at: 300)
        #expect(idle.deadline == 900)
        idle.note(.init(reading: false, waiting: 0, turnActive: false, inBackground: true), at: 500)
        #expect(idle.deadline == 900)
    }

    @Test func inTheForegroundItNeverPausesAndGoingBackStartsTheCount() {
        var idle = AutoReadIdle()
        idle.note(.init(reading: false, waiting: 0, turnActive: false, inBackground: false), at: 0)
        #expect(idle.deadline == nil)
        idle.note(.init(reading: false, waiting: 0, turnActive: false, inBackground: true), at: 1_000)
        #expect(idle.deadline == 1_600)
    }
}
