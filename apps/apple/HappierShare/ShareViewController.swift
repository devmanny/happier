import SwiftUI
#if os(iOS)
import UIKit

/// The share sheet's "Happier": pick a conversation, add a message, and Happier sends it.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext) { [weak self] url in self?.openApp(url) }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// An extension can't open URLs itself; the application at the end of the responder chain can.
    private func openApp(_ url: URL) {
        var responder: UIResponder? = self
        while let next = responder {
            if let application = next as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = next.next
        }
    }
}
#else
import AppKit

final class ShareViewController: NSViewController {
    override func loadView() {
        let model = ShareModel(context: extensionContext) { url in NSWorkspace.shared.open(url) }
        view = NSHostingView(rootView: ShareView(model: model).frame(width: 440, height: 540))
    }
}
#endif
