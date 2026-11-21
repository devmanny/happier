#if os(iOS)
import HappierKit
import os
import SwiftUI

/// The Apple Pencil on a composer (a conversation's and a new session's): two squeezes start
/// dictating, one stops and keeps the text (`PencilSqueezeDictation`); a double tap sends. Only
/// the window with the focus reacts (`FrontWindow.takesInput`), and nothing happens when the
/// Pencil's gesture is set to do nothing.
struct PencilComposerGestures: ViewModifier {
    let recording: Bool
    /// Push to talk is holding the mic: the Pencil leaves it alone.
    let talking: Bool
    let startDictating: () -> Void
    let finishDictating: () -> Void
    let send: () -> Void

    @State private var squeeze = PencilSqueezeDictation()
    @State private var keyWindow = KeyWindowState()
    @Environment(\.appearsActive) private var windowActive
    @Environment(\.preferredPencilSqueezeAction) private var preferredSqueezeAction
    @Environment(\.preferredPencilDoubleTapAction) private var preferredDoubleTapAction

    private static let log = Logger(subsystem: "dev.happier.apple", category: "pencil")

    func body(content: Content) -> some View {
        content
            .background(KeyWindowReader(state: keyWindow))
            .onPencilSqueeze { phase in
                guard case .ended = phase else { return }
                guard accepts("squeeze", enabled: preferredSqueezeAction != .ignore) else { return }
                switch squeeze.squeezed(at: .now, recording: recording) {
                case .start: start()
                case .finish: finishDictating()
                case .none: break
                }
            }
            .onPencilDoubleTap { _ in
                guard accepts("double tap", enabled: preferredDoubleTapAction != .ignore) else { return }
                send()
            }
    }

    /// The keyboard's own dictation holds the microphone: end it (by ending the editing, as
    /// sending does) and give the microphone a moment before ours opens.
    private func start() {
        guard KeyboardDictation.isActive else { return startDictating() }
        Self.log.notice("pencil squeeze: ending the keyboard's dictation first")
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            startDictating()
        }
    }

    private func accepts(_ gesture: StaticString, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard !talking else { return false }
        let touched = TouchedWindow.shared.id
        let onScreen = UIApplication.shared.connectedScenes.filter { $0.activationState == .foregroundActive }.count
        let focused = FrontWindow.takesInput(active: windowActive, isKey: touched != nil && touched == keyWindow.id,
                                             anyWindowIsKey: touched != nil, onlyWindow: onScreen <= 1)
        if !focused {
            Self.log.notice("pencil \(gesture, privacy: .public) ignored: not the window with the focus (active \(windowActive), touched \(touched != nil), windows \(onScreen))")
        }
        return focused
    }
}

extension View {
    func pencilComposerGestures(recording: Bool, talking: Bool, startDictating: @escaping () -> Void,
                                finishDictating: @escaping () -> Void, send: @escaping () -> Void) -> some View {
        modifier(PencilComposerGestures(recording: recording, talking: talking, startDictating: startDictating,
                                        finishDictating: finishDictating, send: send))
    }
}
#endif
