import Foundation
import Testing
@testable import HappierKit

/// Mirrors `apps/ui/sources/sync/ops/sessionStopStrategy.ts`.
@Suite struct SessionStopTests {
    @Test func daemonResultsDecideWhetherToFallBackToTheRunner() {
        #expect(SessionStop.daemonOutcome(["status": "stopped"]) == .stopped)
        #expect(SessionStop.daemonOutcome(["status": "requested"]) == .requested)
        // Released daemons acknowledge with a message only.
        #expect(SessionStop.daemonOutcome(["message": "Session stopped"]) == .requested)
        #expect(SessionStop.daemonOutcome(["status": "not_found"]) == .fallback)
        #expect(SessionStop.daemonOutcome(["error": "Session not found or failed to stop"]) == .fallback)
        #expect(SessionStop.daemonOutcome(["status": "incomplete", "reason": "process_alive"]) == .failed("Session stop incomplete: process_alive"))
        #expect(SessionStop.daemonOutcome(["unexpected": true]) == .failed("Unsupported response from machine RPC"))
    }

    @Test func aLiveRunnerCanOnlyAcknowledgeTheRequest() {
        #expect(SessionStop.runnerOutcome(["status": "stopped"]) == .requested)
        #expect(SessionStop.runnerOutcome(["status": "requested"]) == .requested)
        #expect(SessionStop.runnerOutcome(["success": true]) == .requested)
        #expect(SessionStop.runnerOutcome(["status": "not_found"]) == .failed("Session not found"))
        #expect(SessionStop.runnerOutcome(["success": false, "message": "busy"]) == .failed("busy"))
    }
}
