import Testing
@testable import HappierKit

/// A color per project folder, kept in the synced account settings so every device shows it:
/// all sessions of a folder share it, whichever window or device they're in.
struct FolderColorTests {
    @Test func aFolderKeepsItsColorAcrossItsSessionsAndSlashes() {
        var settings = AccountSettings(values: ["other": "kept"])
        settings = settings.merging(settings.delta(folderColor: AccountSettings.FolderColor.teal, for: "/Users/m/Projects/radar"))
        #expect(settings.folderColor(for: "/Users/m/Projects/radar") == AccountSettings.FolderColor.teal)
        #expect(settings.folderColor(for: "/Users/m/Projects/radar/") == AccountSettings.FolderColor.teal)
        #expect(settings.folderColor(for: "/Users/m/Projects/kineos") == nil)
        #expect(settings.values["other"] == "kept")
    }

    @Test func noneTakesTheColorOffAndLeavesTheOthers() {
        var settings = AccountSettings(values: [:])
        settings = settings.merging(settings.delta(folderColor: AccountSettings.FolderColor.orange, for: "/a"))
        settings = settings.merging(settings.delta(folderColor: AccountSettings.FolderColor.blue, for: "/b"))
        settings = settings.merging(settings.delta(folderColor: nil, for: "/a"))
        #expect(settings.folderColor(for: "/a") == nil)
        #expect(settings.folderColor(for: "/b") == AccountSettings.FolderColor.blue)
    }

    @Test func anUnknownColorFromANewerAppIsIgnored() {
        let settings = AccountSettings(values: [AccountSettings.folderColorsKey: ["/a": "ultraviolet"]])
        #expect(settings.folderColor(for: "/a") == nil)
    }
}
