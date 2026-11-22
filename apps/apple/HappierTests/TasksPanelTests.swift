import SwiftUI
import UIKit
import XCTest
@testable import Happier

/// The Tasks panel on the right is the iPad's and the Mac's; the iPhone keeps its sheet. A large
/// iPhone in landscape has an iPad's width, and rotating it with the panel there closed the app.
final class TasksPanelTests: XCTestCase {
    func testTheIPhoneKeepsItsTasksSheetInLandscapeToo() {
        XCTAssertFalse(TasksPanel.isPart(of: .phone))
        XCTAssertFalse(TasksPanel.shows(on: .phone, sizeClass: .regular))
        XCTAssertFalse(TasksPanel.shows(on: .phone, sizeClass: .compact))
    }

    func testTheIPadHasThePanelInAWideWindowAndKeepsItWhenNarrow() {
        // Part of the layout whatever the window's width, so a resize never adds or removes it.
        XCTAssertTrue(TasksPanel.isPart(of: .pad))
        XCTAssertTrue(TasksPanel.shows(on: .pad, sizeClass: .regular))
        XCTAssertFalse(TasksPanel.shows(on: .pad, sizeClass: .compact))
    }
}
