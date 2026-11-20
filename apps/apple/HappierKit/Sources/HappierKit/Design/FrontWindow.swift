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

    /// Whether this window takes input meant for one window only (an Apple Pencil squeeze opening
    /// the microphone): the window with the focus, the one touched last. Unlike a prompt, it is
    /// never shown in several at once: with none touched yet, only a window alone on screen takes it.
    public static func takesInput(active: Bool, isKey: Bool, anyWindowIsKey: Bool, onlyWindow: Bool) -> Bool {
        active && (isKey || (!anyWindowIsKey && onlyWindow))
    }
}
