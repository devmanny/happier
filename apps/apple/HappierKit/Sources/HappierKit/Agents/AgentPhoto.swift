import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An agent's profile photo (`packages/protocol/src/agentProfiles/agentPhoto.ts`): a small square
/// JPEG sealed for the account's devices under `agentphoto/<id>`, apart from the profile so the
/// profile listing stays light. Synced between iPhone, iPad and Mac.
public struct AgentPhoto: Sendable, Equatable {
    public let id: String
    public var jpeg: Data
    public var updatedAt: Double

    public init(id: String, jpeg: Data, updatedAt: Double = ServerClock.nowMs()) {
        self.id = id.lowercased()
        self.jpeg = jpeg
        self.updatedAt = updatedAt
    }

    public static let kvPrefix = "agentphoto/"

    public static func kvKey(id: String) -> String { kvPrefix + id.lowercased() }

    var json: JSONValue {
        ["v": 1, "id": .string(id), "mime": "image/jpeg", "data": .string(jpeg.base64EncodedString()), "updatedAt": .number(updatedAt)]
    }

    init?(json: JSONValue) {
        guard json["v"]?.intValue == 1, let id = json["id"]?.stringValue, !id.isEmpty, json["mime"]?.stringValue == "image/jpeg",
              let data = json["data"]?.stringValue, let jpeg = Base64.decode(data), !jpeg.isEmpty else { return nil }
        self.init(id: id, jpeg: jpeg, updatedAt: json["updatedAt"]?.doubleValue ?? 0)
    }

    func sealed(machineKey: Data) throws -> String {
        try AccountScopedBlob.seal(json, kind: .agentPhoto, machineKey: machineKey)
    }

    static func open(_ value: String, machineKey: Data) -> AgentPhoto? {
        AccountScopedBlob.open(value, kind: .agentPhoto, machineKey: machineKey).flatMap(AgentPhoto.init(json:))
    }

    /// A picked photo as the agent's: the largest centered square, upright, at most `side` pixels on
    /// a side, as a JPEG small enough to sync (tens of KB). Nil when it isn't an image.
    public static func squareJPEG(from data: Data, side: Int = 512) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        // The thumbnail's longer side such that its shorter side is `side` (never upscaled).
        let scale = min(1, Double(side) / Double(min(width, height)))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Int((Double(max(width, height)) * scale).rounded())]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let edge = min(image.width, image.height)
        guard let square = image.cropping(to: CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2, width: edge, height: edge)) else {
            return nil
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, square, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    struct Record: Sendable, Equatable {
        var photo: AgentPhoto
        var version: Int
    }

    /// Readable photos from a `GET /v1/kv` listing of `agentphoto/`; removed rows (empty value), rows
    /// filed under another agent and rows this device can't open are skipped.
    static func records(fromList response: JSONValue, machineKey: Data) -> [Record] {
        (response["items"]?.arrayValue ?? []).compactMap { item in
            guard let key = item["key"]?.stringValue, key.hasPrefix(kvPrefix),
                  let value = item["value"]?.stringValue, !value.isEmpty,
                  let photo = open(value, machineKey: machineKey), kvKey(id: photo.id) == key else { return nil }
            return Record(photo: photo, version: item["version"]?.intValue ?? 0)
        }
    }
}
