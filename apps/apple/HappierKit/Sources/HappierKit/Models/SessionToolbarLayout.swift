/// The buttons beside a session's title. The title matters most, so the bar holds at most three
/// buttons, two when a back button already sits there (the iPhone, a narrow iPad window); the
/// bell, the session's tasks, the browser and search live in the ⓘ menu, which is always there.
public enum SessionToolbarLayout {
    public enum Slot: Sendable, Equatable {
        /// Read new messages aloud.
        case readAloud
        /// The usage rings.
        case usage
        /// The ⓘ menu.
        case details
    }

    public static func slots(hasBackButton: Bool) -> [Slot] {
        hasBackButton ? [.usage, .details] : [.readAloud, .usage, .details]
    }

    /// Whether "read new messages aloud" is in the ⓘ menu, having no room in the bar.
    public static func readAloudInMenu(hasBackButton: Bool) -> Bool {
        !slots(hasBackButton: hasBackButton).contains(.readAloud)
    }
}
