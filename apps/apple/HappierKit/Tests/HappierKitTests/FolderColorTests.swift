import Foundation
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

    /// Enough colors to tell many projects apart, and none mistaken for another: every pair is at
    /// least a clearly visible step apart (CIE76 ΔE ≥ 15).
    @Test func manyFolderColorsAndNoTwoLookAlike() {
        let all = AccountSettings.FolderColor.allCases
        #expect(all.count >= 19)
        for (index, color) in all.enumerated() {
            for other in all[(index + 1)...] {
                #expect(Self.distance(color.vivid, other.vivid) >= 15, "\(color) and \(other) look alike")
            }
        }
    }

    @Test func aColorFromTheWiderPaletteIsReadBack() {
        var settings = AccountSettings(values: [:])
        settings = settings.merging(settings.delta(folderColor: AccountSettings.FolderColor(rawValue: "navy"), for: "/a"))
        #expect(settings.folderColor(for: "/a")?.rawValue == "navy")
    }

    private static func distance(_ a: AccountSettings.RGB, _ b: AccountSettings.RGB) -> Double {
        func lab(_ c: AccountSettings.RGB) -> (Double, Double, Double) {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = linear(c.red), g = linear(c.green), b = linear(c.blue)
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let p = lab(a), q = lab(b)
        return ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1) + (p.2 - q.2) * (p.2 - q.2)).squareRoot()
    }
}
