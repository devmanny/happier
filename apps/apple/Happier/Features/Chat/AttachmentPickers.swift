import AVFoundation
import HappierKit
import PhotosUI
#if os(iOS)
import QuickLook
#endif
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
            AppHaptics.error()
            let limit = ByteCountFormatter.string(fromByteCount: Int64(HappierStore.maxAttachmentBytes), countStyle: .file)
            store.lastError = String(localized: "\(screened.tooLarge.joined(separator: ", ")) is larger than \(limit).")
        } else if !screened.accepted.isEmpty {
            AppHaptics.success()
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

    #if os(macOS)
    /// Files copied in Finder, as attachments.
    static func clipboardFiles() -> [AttachmentDraft] {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.compactMap(file(at:))
    }

    /// Whether ⌘V should attach rather than paste text: copied files or an image.
    static var clipboardHasAttachments: Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }
    #endif

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
    /// Picked files still being read: drawn as placeholders until they arrive.
    var loading = 0
    #if os(macOS)
    @State private var lookingAt: URL?
    #endif

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { draft in
                    // Tap to see it large; on iPhone and iPad an image can be marked up there
                    // (lines, arrows, text) and the marked-up one is what gets sent.
                    Button { open(draft) } label: { AttachmentThumbnail(draft: draft) }
                        .buttonStyle(.pressable)
                        .accessibilityHint(Text("Opens it large"))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                AppHaptics.light()
                                withAnimation(.smooth) { attachments.removeAll { $0.id == draft.id } }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .font(.title3)
                            }
                            .buttonStyle(.pressable)
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Remove \(draft.name)")
                        }
                }
                ForEach(0..<loading, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 64, height: 64)
                        .overlay { HappierSpinner(size: HappierSpinner.mini) }
                        .accessibilityLabel(Text("Loading attachment"))
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .scrollClipDisabled()
        #if os(macOS)
        .quickLookPreview($lookingAt)
        #endif
    }

    private func open(_ draft: AttachmentDraft) {
        AppHaptics.light()
        guard let file = AttachmentMarkup.temporaryFile(for: draft) else { return }
        #if os(iOS)
        let id = draft.id
        AttachmentMarkup.shared.present(file, editable: AttachmentMarkup.canMarkUp(draft)) { data in
            guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
            AttachmentPreviews.forget(draft.name)
            attachments[index] = AttachmentDraft(name: draft.name, mimeType: draft.mimeType, data: data)
        }
        #else
        lookingAt = file
        #endif
    }
}

/// Opens an attachment not sent yet in the system's viewer; on iPhone and iPad an image or PDF
/// opens with Markup, and what's drawn replaces the attachment.
@MainActor
final class AttachmentMarkup: NSObject {
    static let shared = AttachmentMarkup()

    static func canMarkUp(_ draft: AttachmentDraft) -> Bool {
        guard let mime = draft.mimeType else { return false }
        return mime.hasPrefix("image/") || mime == "application/pdf"
    }

    /// The draft as a file with its name (and an extension the viewer recognizes).
    static func temporaryFile(for draft: AttachmentDraft) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-\(UUID().uuidString)", isDirectory: true)
        var name = draft.name
        if (name as NSString).pathExtension.isEmpty,
           let ext = draft.mimeType.flatMap({ UTType(mimeType: $0)?.preferredFilenameExtension }) {
            name += "." + ext
        }
        let file = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try draft.data.write(to: file)
            return file
        } catch {
            return nil
        }
    }

    #if os(iOS)
    private var file: URL?
    private var editable = false
    private var onEdit: ((Data) -> Void)?

    func present(_ file: URL, editable: Bool, onEdit: @escaping (Data) -> Void) {
        self.file = file
        self.editable = editable
        self.onEdit = onEdit
        let controller = QLPreviewController()
        controller.dataSource = self
        controller.delegate = self
        Self.topController()?.present(controller, animated: true)
    }

    private static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
    #endif
}

#if os(iOS)
extension AttachmentMarkup: QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { (file ?? URL(fileURLWithPath: "/dev/null")) as NSURL }
    }

    nonisolated func previewController(_ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode {
        MainActor.assumeIsolated { editable ? .updateContents : .disabled }
    }

    nonisolated func previewController(_ controller: QLPreviewController, didUpdateContentsOf previewItem: any QLPreviewItem) {
        guard let url = previewItem.previewItemURL, let data = try? Data(contentsOf: url) else { return }
        Task { @MainActor in self.onEdit?(data) }
    }
}
#endif

/// Preview frame for a picked attachment: the image itself, or a frame of the video, and a copy
/// of the file for Quick Look.
struct AttachmentPreview: Sendable {
    let image: Data
    let videoDuration: Double?
    let fileURL: URL?
}

/// Previews for this device's attachments, keyed by file name (names are timestamped, so unique),
/// so sent bubbles can show the same thumbnails the composer showed.
@MainActor
enum AttachmentPreviews {
    private static var cache: [String: AttachmentPreview] = [:]

    static func cached(_ name: String) -> AttachmentPreview? { cache[name] }

    /// The attachment changed (marked up): its preview and kept copy are made again from the new image.
    static func forget(_ name: String) {
        cache[name] = nil
        let kept = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Happier/Attachments").appending(path: name)
        try? FileManager.default.removeItem(at: kept)
    }

    static func preview(for draft: AttachmentDraft) async -> AttachmentPreview? {
        if let hit = cache[draft.name] { return hit }
        let made: AttachmentPreview?
        if draft.mimeType?.hasPrefix("video/") == true {
            made = await videoPreview(draft)
        } else if draft.isImage {
            made = AttachmentPreview(image: draft.data, videoDuration: nil, fileURL: keep(draft))
        } else {
            made = nil
        }
        if let made { cache[draft.name] = made }
        return made
    }

    /// The attachment as a file in Caches, under its own (timestamped, unique) name.
    private static func keep(_ draft: AttachmentDraft) -> URL? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Happier/Attachments")
        let url = directory.appending(path: draft.name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try draft.data.write(to: url) }
            return url
        } catch {
            return nil
        }
    }

    private static func videoPreview(_ draft: AttachmentDraft) async -> AttachmentPreview? {
        guard let url = keep(draft) else { return nil }
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
        return AttachmentPreview(image: jpeg, videoDuration: duration, fileURL: url)
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

/// The pickers behind the ⊕ menu (photos and videos, files, the camera), the same for every
/// composer: a live conversation's and a new session's.
struct AttachmentSources: ViewModifier {
    @Binding var showPhotos: Bool
    @Binding var showFiles: Bool
    @Binding var showCamera: Bool
    @Binding var showCameraPermission: Bool
    /// Picked photos and videos still being read. While it isn't zero, the message must not go:
    /// it would leave without them.
    @Binding var loading: Int
    let onAdd: ([AttachmentDraft]) -> Void
    @Environment(HappierStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var photoItems: [PhotosPickerItem] = []

    /// Asks for the camera, opening it when allowed and explaining how to allow it when not.
    static func openCamera(show: Binding<Bool>, denied: Binding<Bool>) {
        #if os(iOS)
        Task {
            guard CameraPicker.isAvailable else { return }
            if await CameraPicker.requestAccess() { show.wrappedValue = true } else { denied.wrappedValue = true }
        }
        #endif
    }

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                loading += items.count
                Task {
                    let drafts = await AttachmentLoader.drafts(from: items)
                    loading -= items.count
                    // One that can't be read (an iCloud original that won't download) is said, not dropped.
                    let missing = items.count - drafts.count
                    if missing > 0 {
                        AppHaptics.error()
                        store.lastError = missing == items.count
                            ? String(localized: "The selected photos couldn't be loaded. Try picking them again.")
                            : String(localized: "\(missing) of the selected items couldn't be loaded.")
                    }
                    onAdd(drafts)
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                onAdd(((try? result.get()) ?? []).compactMap(AttachmentLoader.file(at:)))
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { outcome in
                    showCamera = false
                    switch outcome {
                    case .photo(let data): onAdd([AttachmentLoader.photo(data)])
                    case .cancelled: break
                    case .failed:
                        AppHaptics.error()
                        store.lastError = String(localized: "The photo couldn't be captured. Please try again.")
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Camera Access", isPresented: $showCameraPermission) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Allow camera access in Settings to take a photo and attach it to your message.")
            }
            #endif
    }
}
