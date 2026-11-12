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

    /// Your bubbles and the avatar's disc take the folder's color with white text on it: each
    /// must stay readable, and (gray aside) vivid rather than a system color mixed with black.
    @Test func everyFolderColorIsVividAndReadableUnderWhiteText() {
        for color in AccountSettings.FolderColor.allCases {
            let rgb = color.vivid
            #expect(rgb.contrastWithWhite >= 3, "\(color) is too light for white text")
            guard color != .gray else { continue }
            let high = max(rgb.red, rgb.green, rgb.blue), low = min(rgb.red, rgb.green, rgb.blue)
            #expect(high >= 0.6, "\(color) is too dark to read as a color")
            #expect((high - low) / high >= 0.6, "\(color) is washed out")
        }
    }

    @Test func noTwoFolderColorsLookTheSame() {
        let all = AccountSettings.FolderColor.allCases.map(\.vivid)
        #expect(Set(all.map { "\($0.red) \($0.green) \($0.blue)" }).count == all.count)
    }
}
