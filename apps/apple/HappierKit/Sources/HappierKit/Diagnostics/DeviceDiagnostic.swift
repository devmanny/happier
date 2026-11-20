import Foundation

/// MetricKit reports (crashes, hangs, daily metrics) saved for the developer in the account's own
/// UserKVStore, one per key `diag/<uuid>`, sealed `device_diagnostics`
/// (`packages/protocol/src/diagnostics/deviceDiagnostics.ts`). `happier diagnostics pull` writes
/// them to files and deletes them; nothing in the app reads them back.
public enum DeviceDiagnostic {
    public enum Kind: String, Sendable { case diagnostic, metric }

    /// The device and build a report came from.
    public struct Origin: Sendable, Equatable {
        public let model: String
        public let os: String
        public let appVersion: String
        public let build: String

        public init(model: String, os: String, appVersion: String, build: String) {
            self.model = model
            self.os = os
            self.appVersion = appVersion
            self.build = build
        }
    }

    public static let kvPrefix = "diag/"

    static func kvKey(id: UUID) -> String { kvPrefix + id.uuidString.lowercased() }

    /// The relay's request body limit (`bodyLimit` in `apps/server/sources/app/api/api.ts`).
    static let requestBodyLimit = 100 * 1024 * 1024

    /// The sealed value to write at `key`: the zlib-compressed report, or, when that write wouldn't
    /// fit in one request, a short entry saying how large it was (so it isn't lost silently).
    static func sealedValue(_ json: Data, kind: Kind, origin: Origin, createdAt: Date, key: String, machineKey: Data,
                            requestBodyLimit: Int = requestBodyLimit) throws -> (value: String, tooLarge: Bool) {
        // Apple's zlib is raw DEFLATE (RFC 1951); the CLI inflates it with `inflateRawSync`.
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        let createdAtMs = JSONValue.number((createdAt.timeIntervalSince1970 * 1000).rounded())
        let full: JSONValue = [
            "v": 1, "kind": .string(kind.rawValue), "createdAt": createdAtMs,
            "device": ["model": .string(origin.model), "os": .string(origin.os)],
            "appVersion": .string(origin.appVersion), "build": .string(origin.build),
            "encoding": "zlib", "payloadBase64": .string(compressed.base64EncodedString()),
        ]
        let value = try AccountScopedBlob.seal(full, kind: .deviceDiagnostics, machineKey: machineKey)
        let bodyBytes = try HappierAPI.kvWriteBody(key: key, value: value, version: -1).encoded().count
        if bodyBytes <= requestBodyLimit { return (value, false) }
        let short: JSONValue = [
            "v": 1, "kind": .string(kind.rawValue), "tooLarge": true, "compressedBytes": .number(Double(compressed.count)),
            "rawBytes": .number(Double(json.count)), "build": .string(origin.build), "createdAt": createdAtMs,
        ]
        return (try AccountScopedBlob.seal(short, kind: .deviceDiagnostics, machineKey: machineKey), true)
    }
}
