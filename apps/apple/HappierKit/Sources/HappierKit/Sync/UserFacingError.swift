import Foundation

/// Turns errors into short messages for alerts (never a raw `NSError` dump).
public enum UserFacingError {
    static let timedOut = String(localized: "The server took too long to respond. Check your connection and try again.")
    static let offline = String(localized: "You're offline. Check your connection and try again.")

    /// Cancellations come from leaving a screen or the app; they're never shown.
    public static func isSilent(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    public static func message(for error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .timedOut: return timedOut
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: return offline
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return String(localized: "Can't reach the server.")
            case .secureConnectionFailed, .serverCertificateUntrusted: return String(localized: "The server's secure connection failed.")
            default: return String(localized: "A network error occurred. Try again.")
            }
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        if let custom = error as? CustomStringConvertible { return custom.description }
        return String(localized: "Something went wrong. Try again.")
    }
}
