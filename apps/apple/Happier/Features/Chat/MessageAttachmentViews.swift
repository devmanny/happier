import HappierKit
import SwiftUI

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
            Text("The computer that has it may be offline.")
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
            Text("The computer that has it may be offline.")
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
