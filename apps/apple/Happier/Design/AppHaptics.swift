import Foundation
#if os(iOS)
import UIKit
#endif

/// Feedback for deliberate interactions. Call from the action itself, never a live-data update.
@MainActor
enum AppHaptics {
    /// Settings → Appearance → Haptics (this device only).
    static let enabledKey = "happier.hapticsEnabled"
    private static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    #if os(iOS)
    private static let selectionFeedback = UISelectionFeedbackGenerator()
    private static let lightFeedback = UIImpactFeedbackGenerator(style: .light)
    private static let confirmFeedback = UIImpactFeedbackGenerator(style: .medium)
    private static let notificationFeedback = UINotificationFeedbackGenerator()
    #endif

    static func selection() {
        guard isEnabled else { return }
        #if os(iOS)
        selectionFeedback.selectionChanged()
        #endif
    }

    static func light() {
        guard isEnabled else { return }
        #if os(iOS)
        lightFeedback.impactOccurred()
        #endif
    }

    /// The app accepted a primary action, such as send; this does not claim server delivery.
    static func confirm() {
        guard isEnabled else { return }
        #if os(iOS)
        confirmFeedback.impactOccurred()
        #endif
    }

    static func success() {
        guard isEnabled else { return }
        #if os(iOS)
        notificationFeedback.notificationOccurred(.success)
        #endif
    }

    static func warning() {
        guard isEnabled else { return }
        #if os(iOS)
        notificationFeedback.notificationOccurred(.warning)
        #endif
    }

    static func error() {
        guard isEnabled else { return }
        #if os(iOS)
        notificationFeedback.notificationOccurred(.error)
        #endif
    }
}
