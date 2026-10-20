import AVFoundation
import HappierKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Turns picked photos and files into upload drafts. Photos are re-encoded as JPEG so agents can
/// read them regardless of the library's HEIC originals.
enum AttachmentLoader {
    static func drafts(from items: [PhotosPickerItem]) async -> [AttachmentDraft] {
        var drafts: [AttachmentDraft] = []
        for (offset, item) in items.enumerated() {
            if let type = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) }) {
                // Videos arrive as a file (works for large and iCloud-backed assets).
                // Mapped, not loaded: a long video is read chunk by chunk while it uploads.
                guard let movie = try? await item.loadTransferable(type: PickedMovie.self),
                      let data = try? Data(contentsOf: movie.url, options: .alwaysMapped) else { continue }
                let ext = movie.url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "mov") : movie.url.pathExtension
                let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? type.preferredMIMEType ?? "video/quicktime"
                drafts.append(AttachmentDraft(name: "video-\(stamp)-\(offset + 1).\(ext)", mimeType: mime, data: data))
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                drafts.append(photo(data, index: offset))
            }
        }
        return drafts
    }

    /// Adds picked or dropped files, turning away ones over the upload limit up front.
    @MainActor
    static func add(_ drafts: [AttachmentDraft], to attachments: Binding<[AttachmentDraft]>, store: HappierStore) {
        let screened = HappierStore.screenAttachments(drafts)
        if !screened.tooLarge.isEmpty {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(HappierStore.maxAttachmentBytes), countStyle: .file)
            store.lastError = String(localized: "\(screened.tooLarge.joined(separator: ", ")) is larger than \(limit).")
        }
        withAnimation(.smooth) { attachments.wrappedValue += screened.accepted }
    }

    private static var stamp: String {
        Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
    }

    static func photo(_ data: Data, index: Int = 0) -> AttachmentDraft {
        if let jpeg = jpegData(data) {
            return AttachmentDraft(name: "photo-\(stamp)-\(index + 1).jpg", mimeType: "image/jpeg", data: jpeg)
        }
        return AttachmentDraft(name: "photo-\(stamp)-\(index + 1)", mimeType: "image/*", data: data)
    }

    static func file(at url: URL) -> AttachmentDraft? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        return AttachmentDraft(name: url.lastPathComponent, mimeType: type?.preferredMIMEType, data: data)
    }

    static func clipboardText() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    /// The clipboard image as a JPEG draft (RN "Paste image").
    static func clipboardImage() -> AttachmentDraft? {
        #if os(iOS)
        guard let data = UIPasteboard.general.image?.jpegData(compressionQuality: 0.85) else { return nil }
        #else
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
              let data = image.tiffRepresentation else { return nil }
        #endif
        return photo(data)
    }

    private static func jpegData(_ data: Data) -> Data? {
        #if os(iOS)
        return UIImage(data: data)?.jpegData(compressionQuality: 0.85)
        #else
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        #endif
    }
}

/// A file or image dragged onto the conversation: a screenshot thumbnail, a photo from another app,
/// or a file from Finder/Files.
struct DroppedAttachment: Transferable {
    let draft: AttachmentDraft

    static var transferRepresentation: some TransferRepresentation {
        // Files keep their name and type (a screenshot arrives as "Screenshot ….png").
        FileRepresentation(importedContentType: .item) { received in
            guard let draft = AttachmentLoader.file(at: received.file) else { throw CocoaError(.fileReadUnknown) }
            return DroppedAttachment(draft: draft)
        }
        // Image data without a file behind it.
        DataRepresentation(importedContentType: .image) { data in
            DroppedAttachment(draft: AttachmentLoader.photo(data))
        }
    }
}

/// A library video received as a file copy in our temporary directory.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Picked attachments inside the composer card, removable before sending.
struct AttachmentStrip: View {
    @Binding var attachments: [AttachmentDraft]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { draft in
                    AttachmentThumbnail(draft: draft)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                withAnimation(.smooth) { attachments.removeAll { $0.id == draft.id } }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Remove \(draft.name)")
                        }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .scrollClipDisabled()
    }
}

/// Preview frame for a picked attachment: the image itself, or a frame of the video.
struct AttachmentPreview: Sendable {
    let image: Data
    let videoDuration: Double?
}

/// Previews for this device's attachments, keyed by file name (names are timestamped, so unique),
/// so sent bubbles can show the same thumbnails the composer showed.
@MainActor
enum AttachmentPreviews {
    private static var cache: [String: AttachmentPreview] = [:]

    static func cached(_ name: String) -> AttachmentPreview? { cache[name] }

    static func preview(for draft: AttachmentDraft) async -> AttachmentPreview? {
        if let hit = cache[draft.name] { return hit }
        let made: AttachmentPreview?
        if draft.mimeType?.hasPrefix("video/") == true {
            made = await videoPreview(draft)
        } else if draft.isImage {
            made = AttachmentPreview(image: draft.data, videoDuration: nil)
        } else {
            made = nil
        }
        if let made { cache[draft.name] = made }
        return made
    }

    private static func videoPreview(_ draft: AttachmentDraft) async -> AttachmentPreview? {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            .appendingPathExtension((draft.name as NSString).pathExtension)
        guard (try? draft.data.write(to: url)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        guard let frame = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return nil }
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        #if os(iOS)
        guard let jpeg = UIImage(cgImage: frame).jpegData(compressionQuality: 0.8) else { return nil }
        #else
        guard let jpeg = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        #endif
        return AttachmentPreview(image: jpeg, videoDuration: duration)
    }
}

/// Square thumbnail with a play badge and duration for videos.
struct PreviewTile: View {
    let preview: AttachmentPreview
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let image = Self.image(preview.image) {
                image.resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 18 : 14, style: .continuous))
        .overlay {
            if preview.videoDuration != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.22, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(size * 0.14)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let duration = preview.videoDuration {
                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(5)
            }
        }
        .accessibilityLabel(preview.videoDuration != nil ? Text("Video") : Text("Image"))
    }

    static func image(_ data: Data) -> Image? {
        #if os(iOS)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }
}

private struct AttachmentThumbnail: View {
    let draft: AttachmentDraft
    @State private var preview: AttachmentPreview?

    var body: some View {
        Group {
            if let preview {
                PreviewTile(preview: preview)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: draft.mimeType?.hasPrefix("video/") == true ? "film" : "doc").font(.title3)
                    Text(draft.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                }
                .padding(6)
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .task(id: draft.id) { preview = await AttachmentPreviews.preview(for: draft) }
    }
}
