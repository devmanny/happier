import AVFoundation
import XCTest
@testable import Happier

/// Tapping the microphone in a format the hardware can't give raises an Objective-C exception that
/// quits the app, so the format is checked first.
final class MicrophoneFormatTests: XCTestCase {
    private func format(_ rate: Double, _ channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)
            ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    }

    /// A Mac mini with no microphone: the hardware reads 0 Hz with no channels while the output
    /// side still claims 44.1 kHz stereo (what `AVAudioEngine` reported when dictation crashed).
    func testNoMicrophoneIsNotTapped() throws {
        let none = try XCTUnwrap(AVAudioFormat(streamDescription: [AudioStreamBasicDescription(
            mSampleRate: 0, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 0, mBitsPerChannel: 32, mReserved: 0)]))
        XCTAssertNil(Microphone.usableTapFormat(hardware: none, output: format(44_100, 2)))
    }

    func testARateTheHardwareDoesntRunAtIsNotTapped() {
        XCTAssertNil(Microphone.usableTapFormat(hardware: format(16_000, 1), output: format(48_000, 1)))
    }

    func testAWorkingMicrophoneIsTappedInItsOutputFormat() {
        let output = format(48_000, 1)
        XCTAssertEqual(Microphone.usableTapFormat(hardware: format(48_000, 2), output: output), output)
    }
}
