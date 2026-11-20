import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small JPEG of an attachment (a video's first frame), carried in the message so every device
/// can show it without downloading the file. The official client ignores the extra meta key.
public struct AttachmentThumbnail: Equatable, Sendable {
    public let jpeg: Data
    public let width: Int
    public let height: Int
    /// For a video.
    public let durationSeconds: Double?

    public init(jpeg: Data, width: Int, height: Int, durationSeconds: Double?) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
    }

    static let metaKey = "happierAttachmentPreviewsV1"
    /// Longest side, in pixels: sharp in a chat tile, a few KB in the message.
    public static let maxSide = 320

    func json(path: String) -> JSONValue {
        var object: [String: JSONValue] = ["path": .string(path), "jpegBase64": .string(jpeg.base64EncodedString()),
                                           "width": .number(Double(width)), "height": .number(Double(height))]
        if let durationSeconds { object["durationSeconds"] = .number(durationSeconds) }
        return .object(object)
    }

    init?(json: JSONValue) {
        guard let base64 = json["jpegBase64"]?.stringValue, let jpeg = Data(base64Encoded: base64),
              let width = json["width"]?.intValue, let height = json["height"]?.intValue else { return nil }
        self.init(jpeg: jpeg, width: width, height: height, durationSeconds: json["durationSeconds"]?.doubleValue)
    }

    /// From an image or a video's bytes; nil for other files or what can't be read.
    public static func make(data: Data, mimeType: String?) async -> AttachmentThumbnail? {
        let type = mimeType?.lowercased() ?? ""
        if type.hasPrefix("video/") { return await video(data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return image(from: source)
    }

    /// From a file on disk (a downloaded attachment).
    public static func make(fileURL: URL, mimeType: String?) async -> AttachmentThumbnail? {
        if mimeType?.lowercased().hasPrefix("video/") == true { return await video(at: fileURL) }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return image(from: source)
    }

    private static func image(from source: CGImageSource) -> AttachmentThumbnail? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image, durationSeconds: nil)
    }

    private static func video(_ data: Data) async -> AttachmentThumbnail? {
        let url = FileManager.default.temporaryDirectory.appending(path: "thumb-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil else { return nil }
        return await video(at: url)
    }

    private static func video(at url: URL) async -> AttachmentThumbnail? {
        // The watch never attaches videos; it has no frame extraction either.
        #if os(watchOS)
        return nil
        #else
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        guard let frame = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return nil }
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        return encode(frame, durationSeconds: duration)
        #endif
    }

    private static func encode(_ image: CGImage, durationSeconds: Double?) -> AttachmentThumbnail? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return AttachmentThumbnail(jpeg: data as Data, width: image.width, height: image.height, durationSeconds: durationSeconds)
    }
}

/// A file attached to a sent message (`attachments.v1`): where it lives on the session's machine,
/// and its preview when the sender included one.
public struct MessageAttachment: Identifiable, Equatable, Sendable {
    public var id: String { path ?? name }
    public let name: String
    /// On the session's machine, as the daemon stored it (relative to the session folder).
    public let path: String?
    public let mimeType: String?
    public let sizeBytes: Int?
    public let sha256: String?
    public let thumbnail: AttachmentThumbnail?

    public init(name: String, path: String? = nil, mimeType: String? = nil, sizeBytes: Int? = nil, sha256: String? = nil,
                thumbnail: AttachmentThumbnail? = nil) {
        self.name = name
        self.path = path
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.thumbnail = thumbnail
    }

    public var isVideo: Bool {
        if let mimeType { return mimeType.lowercased().hasPrefix("video/") }
        return UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .movie) ?? false
    }

    public var isImage: Bool {
        if let mimeType { return mimeType.lowercased().hasPrefix("image/") }
        return UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) ?? false
    }

    /// The files of a message's `meta`, with the previews the sender added.
    static func list(in meta: JSONValue?) -> [MessageAttachment] {
        guard let meta, meta["happier"]?["kind"]?.stringValue == "attachments.v1" else { return [] }
        var previews: [String: AttachmentThumbnail] = [:]
        for entry in meta[AttachmentThumbnail.metaKey]?["previews"]?.arrayValue ?? [] {
            if let path = entry["path"]?.stringValue, let thumbnail = AttachmentThumbnail(json: entry) { previews[path] = thumbnail }
        }
        return (meta["happier"]?["payload"]?["attachments"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue else { return nil }
            let path = entry["path"]?.stringValue
            return MessageAttachment(name: name, path: path, mimeType: entry["mimeType"]?.stringValue,
                                     sizeBytes: entry["sizeBytes"]?.intValue, sha256: entry["sha256"]?.stringValue,
                                     thumbnail: path.flatMap { previews[$0] })
        }
    }
}
