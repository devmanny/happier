import Foundation

/// JSON-over-HTTP transport for the Happier server (`/v1`, `/v2` routes, Bearer auth).
public struct HTTPClient: Sendable {
    public struct ServerError: Error, CustomStringConvertible {
        public let status: Int
        public let path: String
        public let body: JSONValue?
        public var description: String {
            let detail = body?["error"]?.stringValue ?? body?["message"]?.stringValue ?? ""
            return "HTTP \(status) \(path) \(detail)"
        }
    }

    public let baseURL: URL
    public var token: String?
    private let session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func get(_ path: String, query: [String: String] = [:]) async throws -> JSONValue {
        try await send("GET", path, query: query, body: nil)
    }

    public func post(_ path: String, _ body: JSONValue = [:]) async throws -> JSONValue {
        try await send("POST", path, query: [:], body: body)
    }

    public func put(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        try await send("PUT", path, query: [:], body: body)
    }

    public func patch(_ path: String, _ body: JSONValue) async throws -> JSONValue {
        try await send("PATCH", path, query: [:], body: body)
    }

    public func delete(_ path: String) async throws -> JSONValue {
        try await send("DELETE", path, query: [:], body: nil)
    }

    private func send(_ method: String, _ path: String, query: [String: String], body: JSONValue?) async throws -> JSONValue {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.encoded()
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = data.isEmpty ? JSONValue.null : (try? JSONValue.parse(data))
        guard (200..<300).contains(status) else { throw ServerError(status: status, path: path, body: json) }
        return json ?? .null
    }
}
