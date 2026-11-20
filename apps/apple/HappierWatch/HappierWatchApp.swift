import HappierKit
import SwiftUI

@main
struct HappierWatchApp: App {
    @State private var phone = PhoneLink.shared

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $phone.path) {
                HomeView()
                    .navigationDestination(for: String.self) { sessionId in
                        SessionView(sessionId: sessionId)
                    }
            }
            .environment(phone)
            // A complication tapped: straight to that session.
            .onOpenURL { url in
                guard url.scheme == "happier-watch", url.host == "session", let id = url.pathComponents.dropFirst().first else { return }
                phone.path = [id]
            }
        }
    }
}
