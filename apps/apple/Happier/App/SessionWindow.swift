import HappierKit
import SwiftUI
#if os(iOS)
import UIKit.UIGestureRecognizerSubclass
#endif

/// One conversation in a window of its own ("Open in New Window", Mac and iPad). It reads the same
/// store as the main window, so both show every change; the main window keeps the session.
struct SessionWindow: View {
    static let id = "session"

    let sessionId: String?
    @Environment(HappierStore.self) private var store

    var body: some View {
        NavigationStack {
            if let sessionId, store.sessions.keys.contains(sessionId) {
                ChatView(sessionId: sessionId)
                    .id(sessionId)
            } else if store.phase != .ready || !store.hasLoadedSessions {
                HappierSpinner(size: HappierSpinner.hero)
            } else {
                ContentUnavailableView("Conversation Not Found", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("It may have been archived or deleted."))
            }
        }
        .environment(\.inSessionWindow, true)
        // A window restored on launch without the main one still needs the store started.
        .task { store.restore() }
        .modifier(StoreAlerts())
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

extension EnvironmentValues {
    /// Inside a conversation's own window, where "Open in New Window" would only point at itself.
    @Entry var inSessionWindow = false
}

/// The store's app-wide prompts (stop confirmation, errors), shown once, in the window in front,
/// rather than in every open window at the same time.
struct StoreAlerts: ViewModifier {
    @Environment(HappierStore.self) private var store
    @Environment(\.appearsActive) private var windowActive
    #if os(iOS)
    /// iPad keeps every visible window active; only the one touched last shows a prompt.
    @State private var keyWindow = KeyWindowState()
    private var appearsActive: Bool {
        let touched = TouchedWindow.shared.id
        return FrontWindow.showsPrompts(active: windowActive, isKey: touched != nil && touched == keyWindow.id, anyWindowIsKey: touched != nil)
    }
    #else
    private var appearsActive: Bool { windowActive }
    #endif

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .background(KeyWindowReader(state: keyWindow))
            #endif
            .confirmationDialog(
                store.stopRequest?.thenArchive == true ? "Stop and archive this session?" : "Stop this session?",
                isPresented: Binding(get: { appearsActive && store.stopRequest != nil }, set: { if !$0 { store.stopRequest = nil } }),
                titleVisibility: .visible,
                presenting: store.stopRequest
            ) { request in
                Button(request.thenArchive ? "Stop and Archive" : "Stop Session", role: .destructive) {
                    AppHaptics.warning()
                    Task { await store.confirmStop(request) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The agent's process on the machine will be stopped.")
            }
            // On its own view: two alerts on one view can keep the second from showing.
            .background {
                Color.clear.alert(
                    "Delete this session?",
                    isPresented: Binding(get: { appearsActive && store.deleteRequest != nil }, set: { if !$0 { store.deleteRequest = nil } }),
                    presenting: store.deleteRequest
                ) { session in
                    Button("Delete Session", role: .destructive) {
                        AppHaptics.warning()
                        Task { await store.confirmDelete(session) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { session in
                    Text("“\(session.title)” and all its messages will be permanently deleted from every device. This can't be undone.")
                }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { appearsActive && store.lastError != nil }, set: { if !$0 { store.lastError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "")
            }
    }
}

extension View {
    /// Cut off from the relay: said under the screen's own bar, not as an alert; gone on
    /// reconnecting. Inside the navigation (the list, the conversation), so it never covers the
    /// bar's buttons.
    func offlineNotice() -> some View { modifier(OfflineNoticeInset()) }
}

private struct OfflineNoticeInset: ViewModifier {
    @Environment(HappierStore.self) private var store

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let notice = store.offlineNotice {
                    OfflineBanner(notice: notice)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: store.offlineNotice)
    }
}

/// This device can't reach the relay: what it means for the sessions, without blaming them.
private struct OfflineBanner: View {
    let notice: HappierStore.OfflineNotice

    var body: some View {
        Label {
            Text(notice.message)
        } icon: {
            Image(systemName: notice == .noNetwork ? "wifi.slash" : "icloud.slash")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

#if os(iOS)
/// The window the user touched last. `UIWindow.isKeyWindow` can't tell: on iPad each scene's
/// window is key within its own scene, so every visible window reports it.
@MainActor @Observable
final class TouchedWindow {
    static let shared = TouchedWindow()
    var id: ObjectIdentifier?
}

/// The window holding a view, as the id `TouchedWindow` compares against.
@MainActor @Observable
final class KeyWindowState {
    var id: ObjectIdentifier?
}

private struct KeyWindowReader: UIViewRepresentable {
    let state: KeyWindowState

    func makeUIView(context: Context) -> Probe { Probe(state: state) }
    func updateUIView(_ view: Probe, context: Context) {}

    final class Probe: UIView {
        private let state: KeyWindowState
        private var watcher: TouchWatcher?

        init(state: KeyWindowState) {
            self.state = state
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            guard let old = window, old !== newWindow else { return }
            if let watcher { old.removeGestureRecognizer(watcher) }
            watcher = nil
            // A closed window can't be the one in front: any active window shows the prompt.
            if TouchedWindow.shared.id == ObjectIdentifier(old) { TouchedWindow.shared.id = nil }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            state.id = window.map(ObjectIdentifier.init)
            guard let window, watcher == nil else { return }
            let watcher = TouchWatcher { [weak window] in
                guard let window else { return }
                let id = ObjectIdentifier(window)
                if TouchedWindow.shared.id != id { TouchedWindow.shared.id = id }
            }
            window.addGestureRecognizer(watcher)
            self.watcher = watcher
        }
    }
}

/// Sees every touch that lands in a window and takes none of them.
private final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let touched: () -> Void

    init(touched: @escaping () -> Void) {
        self.touched = touched
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        touched()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
