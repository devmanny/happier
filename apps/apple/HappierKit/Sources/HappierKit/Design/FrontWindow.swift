import Foundation

/// Which window shows the store's app-wide prompts (stop confirmation, delete, errors). On the Mac
/// one window is active at a time. On iPad every visible window of the app is active at once, so
/// the prompt goes to the window touched last (`isKey`; UIKit's own key window is per scene, so
/// every window reports it); if none was touched, an active window still shows it, so a prompt is
/// never lost.
public enum FrontWindow {
    public static func showsPrompts(active: Bool, isKey: Bool, anyWindowIsKey: Bool) -> Bool {
        active && (isKey || !anyWindowIsKey)
    }
}
