import Foundation

/// The local, one-site handoff from the Safari extension. Cookie values never leave this device.
public struct SafariCookieImport: Codable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let origin: URL
    public let cookies: [Cookie]

    public struct Cookie: Codable, Sendable {
        public let name: String
        public let value: String
        public let domain: String
        public let path: String
        public let secure: Bool
        public let httpOnly: Bool
        public let hostOnly: Bool
        public let session: Bool
        public let expirationDate: Double?
        public let sameSite: String
        public let partitionKey: JSONValue?
        public let partitioned: Bool?
    }

    public enum Failure: Error { case invalid, expired, unavailable }

    // A handoff is for the immediate Safari → Happier review, never a backup of browser logins.
    public static let lifetime: TimeInterval = 10 * 60

    private struct Message: Decodable {
        let version: Int
        let origin: URL
        let cookies: [Cookie]
    }

    public static func prepare(message data: Data, now: Date = .now) throws -> Self {
        let message: Message
        do { message = try JSONDecoder().decode(Message.self, from: data) }
        catch { throw Failure.invalid }
        guard message.version == 1, !message.cookies.isEmpty else { throw Failure.invalid }
        let transfer = Self(id: UUID(), createdAt: now, origin: message.origin, cookies: message.cookies)
        _ = try transfer.httpCookies(now: now)
        return transfer
    }

    public func httpCookies(now: Date = .now) throws -> [HTTPCookie] {
        guard now >= createdAt, now.timeIntervalSince(createdAt) < Self.lifetime else { throw Failure.expired }
        guard let components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme),
              let host = components.host?.lowercased(), Self.validHost(host),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/", !cookies.isEmpty else { throw Failure.invalid }
        var identities: Set<String> = []
        return try cookies.map { raw in
            let domain = raw.domain.hasPrefix(".") ? String(raw.domain.dropFirst()) : raw.domain
            guard Self.validHost(domain), domain == domain.lowercased(),
                  raw.hostOnly ? raw.domain == host : (host == domain || host.hasSuffix("." + domain)),
                  raw.partitionKey == nil || raw.partitionKey == .null, raw.partitioned != true,
                  !raw.name.isEmpty, raw.name.utf8.allSatisfy({ byte in
                      byte > 32 && byte < 127 && !Array("()<>@,;:\\\"/[]?={} ".utf8).contains(byte)
                  }),
                  Self.safeField(raw.value), Self.safeField(raw.path), raw.path.hasPrefix("/"),
                  !raw.value.contains(";"), !raw.path.contains(";"),
                  !raw.secure || components.scheme == "https",
                  !raw.name.hasPrefix("__Secure-") || raw.secure,
                  !raw.name.hasPrefix("__Host-") || (raw.secure && raw.hostOnly && raw.path == "/"),
                  !raw.name.hasPrefix("__Http-") || (raw.secure && raw.httpOnly),
                  !raw.name.hasPrefix("__Host-Http-") || raw.httpOnly else { throw Failure.invalid }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: raw.name, .value: raw.value, .domain: raw.hostOnly ? domain : "." + domain,
                .path: raw.path, .originURL: origin,
            ]
            if raw.secure { properties[.secure] = "TRUE" }
            if raw.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if !raw.session {
                guard let expiry = raw.expirationDate, expiry.isFinite, expiry > now.timeIntervalSince1970 else {
                    throw Failure.expired
                }
                properties[.expires] = Date(timeIntervalSince1970: expiry)
            }
            switch raw.sameSite {
            case "strict", "lax": properties[.sameSitePolicy] = raw.sameSite
            case "no_restriction":
                guard raw.secure else { throw Failure.invalid }
                properties[.sameSitePolicy] = "none"
            // WebKit round-trips unspecified as "none". Reject it rather than widening scope.
            default: throw Failure.invalid
            }
            guard identities.insert("\(raw.name)\n\(domain)\n\(raw.path)").inserted,
                  let cookie = HTTPCookie(properties: properties),
                  cookie.name == raw.name, cookie.value == raw.value, cookie.path == raw.path,
                  cookie.isSecure == raw.secure, cookie.isHTTPOnly == raw.httpOnly,
                  cookie.isSessionOnly == raw.session else { throw Failure.invalid }
            return cookie
        }
    }

    private static func safeField(_ text: String) -> Bool {
        !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix(".") && !host.hasSuffix(".") &&
        host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-") && label.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }
        }
    }
}

/// Protected, expiring App Group files; the URL handed to Happier contains only the UUID.
public struct SafariCookieInbox: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public static var shared: Self? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AttentionSnapshot.appGroup)
            .map { Self(root: $0.appendingPathComponent("SafariCookieInbox", isDirectory: true)) }
    }

    public func save(_ transfer: SafariCookieImport, now: Date = .now) throws {
        _ = try transfer.httpCookies(now: now)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var folder = root
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try folder.setResourceValues(resources)
        prune(now: now)
        let data = try JSONEncoder().encode(transfer)
        #if os(iOS)
        try data.write(to: file(transfer.id), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file(transfer.id), options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(transfer.id).path)
    }

    public func load(_ id: UUID, now: Date = .now) throws -> SafariCookieImport {
        do {
            let transfer = try JSONDecoder().decode(SafariCookieImport.self, from: Data(contentsOf: file(id)))
            guard transfer.id == id else { throw SafariCookieImport.Failure.invalid }
            _ = try transfer.httpCookies(now: now)
            return transfer
        } catch {
            try? remove(id)
            throw error
        }
    }

    public func pending(now: Date = .now) -> [SafariCookieImport] {
        files().compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            return try? load(id, now: now)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: file(id)) }

    public func prune(now: Date = .now) { _ = pending(now: now) }

    private func file(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }
}
