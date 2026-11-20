import Testing
@testable import HappierKit

/// Auto read goes to sleep by itself in the background after 5 minutes with nothing new to read,
/// even while the agent keeps working, so the silent keep-alive and the open socket don't run for
/// hours. It wakes when the app comes back to the foreground.
@Suite struct AutoReadIdleTests {
    @Test func sleepsFiveMinutesAfterTheLastThingToReadInTheBackground() {
        var idle = AutoReadIdle()
        idle.note(.init(reading: false, waiting: 0, inBackground: true), at: 0)
        #expect(idle.deadline == 300)
        let early = idle.sleepIfDue(at: 299)
        #expect(!early)
        let due = idle.sleepIfDue(at: 300)
        #expect(due && idle.isAsleep)
    }

    @Test func eachNewMessageReadRestartsTheCountAndThinkingDoesNot() {
        var idle = AutoReadIdle()
        idle.note(.init(reading: false, waiting: 0, inBackground: true), at: 0)
        // The agent thinks and runs tools (the conversation changes, nothing new to read).
        idle.note(.init(reading: false, waiting: 0, inBackground: true), at: 120)
        idle.note(.init(reading: false, waiting: 0, inBackground: true), at: 240)
        #expect(idle.deadline == 300)
        // A new message is read: the five minutes start again when it's done.
        idle.note(.init(reading: true, waiting: 0, inBackground: true), at: 250)
        idle.note(.init(reading: false, waiting: 0, inBackground: true), at: 280)
        #expect(idle.deadline == 580)
        let early = idle.sleepIfDue(at: 579)
        #expect(!early)
    }

    @Test func aWorkingAgentWithNothingNewToReadStillSleeps() {
        var idle = AutoReadIdle()
        // Reading, or messages waiting their turn, isn't idle.
        idle.note(.init(reading: true, waiting: 0, inBackground: true), at: 0)
        #expect(idle.deadline == nil)
        idle.note(.init(reading: false, waiting: 2, inBackground: true), at: 10)
        #expect(idle.deadline == nil)
        // Idle counts from when the last reading ended, whatever the agent is doing meanwhile.
        idle.note(.init(reading: false, waiting: 0, inBackground: true), at: 100)
        #expect(idle.deadline == 400)
        idle.note(.init(reading: false, waiting: 0, inBackground: true), at: 200)
        #expect(idle.deadline == 400)
    }

    @Test func asleepItStaysAsleepUntilTheForegroundWakesIt() {
        var idle = AutoReadIdle()
        idle.note(.init(reading: false, waiting: 0, inBackground: true), at: 0)
        let slept = idle.sleepIfDue(at: 300)
        #expect(slept)
        idle.note(.init(reading: false, waiting: 0, inBackground: true), at: 400)
        #expect(idle.isAsleep && idle.deadline == nil)
        idle.note(.init(reading: false, waiting: 0, inBackground: false), at: 500)
        #expect(!idle.isAsleep)
        // Back in the background, the count starts again.
        idle.note(.init(reading: false, waiting: 0, inBackground: true), at: 1_000)
        #expect(idle.deadline == 1_300)
    }
}
