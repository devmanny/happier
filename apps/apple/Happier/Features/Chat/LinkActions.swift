import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS)
/// The system share sheet for a link, shown from whatever is in front once the action sheet that
/// asked for it has finished closing (shown from that sheet, it closed along with it).
@MainActor
enum SystemShare {
    static func present(_ url: URL) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.keyWindow,
            var top = window.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let host = top
        let show = {
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = host.view
                popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            host.present(sheet, animated: true)
        }
        if let closing = host.presentedViewController, closing.isBeingDismissed, let coordinator = closing.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in show() }
        } else {
            show()
        }
    }
}
#else
/// A web link's actions as the Mac's own menu at the click: open here or in the default browser
/// (by its name), copy, and the system's Share submenu.
@MainActor
enum LinkMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    static func show(_ url: URL, openInHappier: @escaping () -> Void, copy: @escaping () -> Void) {
        let menu = NSMenu()
        var actions: [Action] = []
        func add(_ title: String, _ symbol: String, _ run: @escaping () -> Void) {
            let action = Action(run)
            actions.append(action)
            let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
            item.target = action
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add(String(localized: "Open in Happier"), "safari") { openInHappier() }
        add(defaultBrowserTitle(for: url), "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
        menu.addItem(.separator())
        add(String(localized: "Copy Link"), "doc.on.doc") { copy() }
        menu.addItem(NSSharingServicePicker(items: [url]).standardShareMenuItem)
        // The targets live as long as the menu is up (popUp returns once it closes).
        withExtendedLifetime(actions) {
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    /// "Open in Safari": the browser that opens web links here.
    private static func defaultBrowserTitle(for url: URL) -> String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return String(localized: "Open in Browser") }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        return String(localized: "Open in \(name)")
    }
}
#endif
