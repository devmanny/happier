import Foundation
import Testing
@testable import HappierKit

/// Squeezing the Apple Pencil Pro dictates into the composer: one squeeze starts the mic, two in
/// quick succession stop it and keep the text, unsent. A lone squeeze while dictating does nothing,
/// so a stray one doesn't cut you off.
struct PencilSqueezeDictationTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func oneSqueezeStartsDictation() {
        var squeeze = PencilSqueezeDictation()
        #expect(squeeze.squeezed(at: t0, recording: false) == .start)
    }

    @Test func twoQuickSqueezesWhileDictatingStopIt() {
        var squeeze = PencilSqueezeDictation()
        #expect(squeeze.squeezed(at: t0, recording: true) == .none)
        #expect(squeeze.squeezed(at: t0.addingTimeInterval(0.4), recording: true) == .finish)
    }

    @Test func aLoneSqueezeWhileDictatingIsIgnored() {
        var squeeze = PencilSqueezeDictation()
        #expect(squeeze.squeezed(at: t0, recording: true) == .none)
        #expect(squeeze.squeezed(at: t0.addingTimeInterval(2), recording: true) == .none)
        // The second of those starts a new pair.
        #expect(squeeze.squeezed(at: t0.addingTimeInterval(2.3), recording: true) == .finish)
    }

    @Test func theSqueezeThatStartedDictationDoesNotCountTowardStoppingIt() {
        var squeeze = PencilSqueezeDictation()
        #expect(squeeze.squeezed(at: t0, recording: false) == .start)
        #expect(squeeze.squeezed(at: t0.addingTimeInterval(0.3), recording: true) == .none)
    }
}
