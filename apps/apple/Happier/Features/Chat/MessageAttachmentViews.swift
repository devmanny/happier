import HappierKit
import SwiftUI
import UniformTypeIdentifiers

/// A message's images and videos, up to three a row so many of them wrap instead of widening the
/// message past the screen, on the sender's side.
struct MessageAttachmentTiles: View {
    let files: [MessageAttachment]
    let sessionId: String
    let fromUser: Bool
    let open: (URL) -> Void

    var body: some View {
        let size: CGFloat = files.count == 1 ? 180 : files.count == 2 ? 110 : 96
        let lines = stride(from: 0, to: files.count, by: 3).map { Array(files[$0..<min($0 + 3, files.count)]) }
        VStack(alignment: fromUser ? .trailing : .leading, spacing: 6) {
            ForEach(lines, id: \.first?.id) { line in
                HStack(spacing: 6) {
                    if fromUser { Spacer(minLength: 56) }
                    ForEach(line) { file in
                        MessageAttachmentTile(file: file, sessionId: sessionId, size: size, open: open)
                    }
                }
            }
        }
    }
}

/// Files the agent sent the user (`SendUserFile`), on its side of the conversation like a
/// message: images and videos as thumbnails (unless it asked for cards), other files as cards,
/// then its caption.
struct SentFilesView: View {
    let sent: SentFiles
    let sessionId: String
    let tail: Bool
    @Environment(\.openSessionFilePreview) private var openFilePreview

    var body: some View {
        let media = sent.attachOnly ? [] : sent.files.filter { $0.isImage || $0.isVideo }
        let cards = sent.files.filter { file in !media.contains { $0.id == file.id } }
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                if !media.isEmpty {
                    MessageAttachmentTiles(files: media, sessionId: sessionId, fromUser: false) { openFilePreview?($0) }
                }
                ForEach(cards) { file in
                    SentFileCard(file: file, sessionId: sessionId) { openFilePreview?($0) }
                }
                if let caption = sent.caption {
                    Text(caption)
                        .textSelection(.enabled)
                        .bubblePadding(fromUser: false)
                        .background(Color.agentBubble, in: BubbleShape(fromUser: false, tail: tail))
                }
            }
            Spacer(minLength: 40)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sent-files")
    }
}

/// A file the agent sent, as a card: its kind, name, type and size. Tap: it comes down from the
/// computer (once per send) and opens in the conversation's preview, which plays audio and video
/// and shares or saves it. A file the computer can't send says so in place; tap to try again.
struct SentFileCard: View {
    let file: MessageAttachment
    let sessionId: String
    let open: (URL) -> Void
    @Environment(HappierStore.self) private var store
    @State private var downloading: Double?
    @State private var unavailable = false

    var body: some View {
        Button {
            AppHaptics.light()
            Task { await fetch() }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let downloading {
                        ProgressRing(fraction: downloading, size: 16)
                    } else {
                        Image(systemName: unavailable ? "questionmark.folder" : symbol)
                            .font(.title2)
                            .foregroundStyle(unavailable ? Color.secondary : Color.userBubble)
                    }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(minWidth: 200, maxWidth: 320, alignment: .leading)
            .background(Color.agentBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.pressable)
        .disabled(downloading != nil || file.path == nil)
        .help(file.path ?? file.name)
        .accessibilityElement(children: .combine)
        .accessibilityHint(unavailable ? Text("Tries to get the file again") : Text("Downloads and opens the file"))
        .accessibilityIdentifier("sent-file-\(file.name)")
    }

    private func fetch() async {
        downloading = 0
        defer { downloading = nil }
        do {
            open(try await store.attachmentFile(file, in: sessionId) { downloading = $0 })
            unavailable = false
        } catch {
            AppHaptics.error()
            unavailable = true
        }
    }

    private var type: UTType? {
        file.mimeType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: (file.name as NSString).pathExtension)
    }

    /// "MP3 audio · 69 KB", or why it can't be opened.
    private var detail: String {
        if unavailable {
            // Cut off from the relay, it's this device, not the computer.
            return store.reachesRelay ? String(localized: "Not available") : String(localized: "Not available while offline")
        }
        let size = file.sizeBytes.map { Int64($0).formatted(.byteCount(style: .file)) }
        let parts = [type?.localizedDescription, size].compactMap { $0 }
        return parts.isEmpty ? String(localized: "File") : parts.joined(separator: " · ")
    }

    private var symbol: String {
        guard let type else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .movie) { return "play.rectangle" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// A sent image or video as a thumbnail: this device's own preview, the one the sender put in
/// the message, or one made from the file (images). Tap: the file comes down from the computer
/// (once) and opens in the system viewer.
struct MessageAttachmentTile: View {
    let file: MessageAttachment
    let sessionId: String
    let size: CGFloat
    let open: (URL) -> Void
    @Environment(HappierStore.self) private var store
    @State private var preview: AttachmentPreview?
    @State private var loading = true
    @State private var downloading: Double?
    @State private var failed = false

    var body: some View {
        Button {
            AppHaptics.light()
            Task { await openFile() }
        } label: {
            ZStack {
                if let preview {
                    PreviewTile(preview: preview, size: size)
                } else {
                    RoundedRectangle(cornerRadius: size > 100 ? 18 : 14, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: size, height: size)
                        .overlay {
                            if loading {
                                HappierSpinner(size: HappierSpinner.mini)
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: file.isVideo ? "play.rectangle" : "photo")
                                        .font(.title2)
                                    Text(file.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                                }
                                .foregroundStyle(.secondary)
                                .padding(6)
                            }
                        }
                }
                if let downloading {
                    ProgressRing(fraction: downloading)
                }
            }
        }
        .buttonStyle(.pressable)
        .disabled(downloading != nil || file.path == nil)
        .accessibilityLabel(Text(file.name))
        .accessibilityHint(Text("Opens the preview"))
        .task(id: file.id) {
            if let local = AttachmentPreviews.cached(file.name) {
                preview = local
            } else if let thumbnail = await store.attachmentThumbnail(file, in: sessionId) {
                preview = AttachmentPreview(image: thumbnail.jpeg, videoDuration: thumbnail.durationSeconds, fileURL: nil)
            }
            loading = false
        }
        .alert("Can't Open the File", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            // Cut off from the relay, it's this device, not the computer.
            Text(store.reachesRelay ? String(localized: "The computer that has it may be offline.") : store.notConnectedMessage)
        }
    }

    private func openFile() async {
        if let local = AttachmentPreviews.cached(file.name)?.fileURL {
            open(local)
            return
        }
        downloading = 0
        defer { downloading = nil }
        do {
            open(try await store.attachmentFile(file, in: sessionId) { downloading = $0 })
        } catch {
            AppHaptics.error()
            failed = true
        }
    }
}

/// A sent file that isn't an image or video: its name; tap to download it and open the preview.
struct MessageAttachmentChip: View {
    let file: MessageAttachment
    let sessionId: String
    let open: (URL) -> Void
    @Environment(HappierStore.self) private var store
    @State private var downloading: Double?
    @State private var failed = false

    var body: some View {
        Button {
            AppHaptics.light()
            Task {
                downloading = 0
                defer { downloading = nil }
                do {
                    open(try await store.attachmentFile(file, in: sessionId) { downloading = $0 })
                } catch {
                    AppHaptics.error()
                    failed = true
                }
            }
        } label: {
            Label {
                Text(file.name).lineLimit(1).truncationMode(.middle)
            } icon: {
                if let downloading {
                    ProgressRing(fraction: downloading, size: 14)
                } else {
                    Image(systemName: "paperclip")
                }
            }
            .font(.footnote.weight(.medium))
        }
        .buttonStyle(.pressable)
        .disabled(downloading != nil || file.path == nil)
        .accessibilityHint(Text("Downloads and opens the file"))
        .alert("Can't Open the File", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            // Cut off from the relay, it's this device, not the computer.
            Text(store.reachesRelay ? String(localized: "The computer that has it may be offline.") : store.notConnectedMessage)
        }
    }
}

/// Download progress over a tile.
private struct ProgressRing: View {
    let fraction: Double
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.35), lineWidth: size / 10)
            Circle()
                .trim(from: 0, to: max(fraction, 0.03))
                .stroke(Color.white, style: StrokeStyle(lineWidth: size / 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .padding(size / 4)
        .background(.black.opacity(0.45), in: Circle())
        .animation(.smooth(duration: 0.2), value: fraction)
    }
}
