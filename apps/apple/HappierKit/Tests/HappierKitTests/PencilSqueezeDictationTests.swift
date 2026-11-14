import Foundation
import Testing
@testable import HappierKit

/// Squeezing the Apple Pencil Pro dictates into the composer: two squeezes in quick succession
/// start the mic, so a stray one doesn't open it; one squeeze while dictating stops it and keeps
/// the text, unsent.
struct PencilSqueezeDictationTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func twoQuickSqueezesStartDictation() {
        var squeeze = PencilSqueezeDictation()
        #expect(squeeze.squeezed(at: t0, recording: false) == .none)
        #expect(squeeze.squeezed(at: t0.addingTimeInterval(0.4), recording: false) == .start)
    }

    @Test func aLoneSqueezeDoesNotOpenTheMic() {
        var squeeze = PencilSqueezeDictation()
        #expect(squeeze.squeezed(at: t0, recording: false) == .none)
        #expect(squeeze.squeezed(at: t0.addingTimeInterval(2), recording: false) == .none)
        // The second of those starts a new pair.
        #expect(squeeze.squeezed(at: t0.addingTimeInterval(2.3), recording: false) == .start)
    }

    @Test func oneSqueezeWhileDictatingStopsIt() {
        var squeeze = PencilSqueezeDictation()
        #expect(squeeze.squeezed(at: t0, recording: true) == .finish)
    }

    @Test func theSqueezeThatStoppedDictationDoesNotCountTowardStartingIt() {
        var squeeze = PencilSqueezeDictation()
        #expect(squeeze.squeezed(at: t0, recording: true) == .finish)
        #expect(squeeze.squeezed(at: t0.addingTimeInterval(0.3), recording: false) == .none)
    }
}
