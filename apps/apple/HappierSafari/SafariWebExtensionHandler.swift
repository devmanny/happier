import Foundation
import HappierKit
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        do {
            guard let request = context.inputItems.first as? NSExtensionItem,
                  let message = request.userInfo?[SFExtensionMessageKey],
                  JSONSerialization.isValidJSONObject(message),
                  let inbox = SafariCookieInbox.shared else { throw SafariCookieImport.Failure.unavailable }
            let transfer = try SafariCookieImport.prepare(message: JSONSerialization.data(withJSONObject: message))
            try inbox.save(transfer)
            response.userInfo = [SFExtensionMessageKey: ["ok": true, "id": transfer.id.uuidString, "count": transfer.cookies.count]]
        } catch {
            // Never send cookie data or parser diagnostics back to a page, logs or analytics.
            response.userInfo = [SFExtensionMessageKey: ["ok": false]]
        }
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
