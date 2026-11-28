import Testing
@testable import HappierKit

/// Daemon versions ordered as the web client orders them (`apps/ui/sources/utils/system/versionUtils.ts`).
@Suite struct CLIVersionTests {
    @Test func ordersReleasesAfterTheirPreviewsAndPreviewsAfterDevBuilds() {
        let minimum = "0.2.10-dev.41"
        #expect(CLIVersion.isAtLeast("0.2.10-dev.41", minimum))
        #expect(CLIVersion.isAtLeast("0.2.10-dev.100", minimum))
        #expect(CLIVersion.isAtLeast("0.2.10-preview.1", minimum))
        #expect(CLIVersion.isAtLeast("0.2.10", minimum))
        #expect(CLIVersion.isAtLeast("0.2.19-dev.3", minimum))
        #expect(!CLIVersion.isAtLeast("0.2.10-dev.40", minimum))
        #expect(!CLIVersion.isAtLeast("0.2.9", minimum))
    }

    @Test func aVersionThatCannotBeOrderedIsNotTakenAsNewEnough() {
        #expect(!CLIVersion.isAtLeast(nil, "0.2.10-dev.41"))
        #expect(!CLIVersion.isAtLeast("", "0.2.10-dev.41"))
        #expect(!CLIVersion.isAtLeast("0.2.19-nightly.1", "0.2.10-dev.41"))
        #expect(!CLIVersion.isAtLeast("main", "0.2.10-dev.41"))
    }
}
