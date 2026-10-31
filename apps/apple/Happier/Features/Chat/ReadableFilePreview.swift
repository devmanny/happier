import HappierKit
import QuickLook
import SwiftUI
#if os(macOS)
import QuickLookUI
#endif

/// A downloaded document and its passive reading copy; the original remains available to share.
struct ReadableFilePreview: Identifiable, Sendable {
    let original: URL
    let formatted: URL
    let markdown: String
    let canReadAloud: Bool

    var id: URL { original }
    var files: [URL] { [formatted, original] }
}

/// Quick Look stays responsible for the document; the chat's reader owns its voice and controls.
struct ReadableFilePreviewView: View {
    let document: ReadableFilePreview
    @Environment(\.dismiss) private var dismiss
    @State private var speaker = MessageSpeaker.shared
    #if os(macOS)
    @State private var showingOriginal = false
    #endif

    private var isReading: Bool { speaker.isSpeaking(document.markdown) }

    var body: some View {
        preview
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isReading {
                    SpeechControls()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("file-preview-speech-controls")
                }
            }
            .onDisappear {
                if isReading { speaker.stop() }
            }
    }

    @ViewBuilder private var preview: some View {
        #if os(iOS)
        DocumentQuickLook(document: document, canStartReading: document.canReadAloud && !isReading,
                          read: read, close: close)
        #else
        DocumentQuickLook(url: showingOriginal ? document.original : document.formatted)
            .safeAreaInset(edge: .top, spacing: 0) {
                // macOS sheets do not provide a navigation toolbar; keep their actions in the sheet.
                HStack(spacing: 16) {
                    Menu {
                        Picker("Document", selection: $showingOriginal) {
                            Text("Formatted").tag(false)
                            Text("Original").tag(true)
                        }
                    } label: {
                        Label("Document", systemImage: "list.bullet")
                    }
                    .help("Document")
                    Text(document.original.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if document.canReadAloud && !isReading {
                        Button("Read Aloud", systemImage: "play.fill", action: read)
                            .accessibilityIdentifier("file-preview-read-aloud")
                            .help("Read Aloud")
                    }
                    ShareLink(item: showingOriginal ? document.original : document.formatted)
                        .help("Share")
                    Button("Close", systemImage: "xmark", action: close)
                        .accessibilityIdentifier("file-preview-close")
                        .help("Close")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(12)
                .background(.bar)
            }
            .frame(minWidth: 420, idealWidth: 760, minHeight: 400, idealHeight: 700)
        #endif
    }

    private func read() {
        AppHaptics.light()
        speaker.toggle(document.markdown)
    }

    private func close() {
        AppHaptics.light()
        dismiss()
    }
}

#if os(iOS)
/// Public Quick Look containment preserves the system document list, sharing, and scrolling.
/// The preview controller is created once; speech updates never reload the document.
private struct DocumentQuickLook: UIViewControllerRepresentable {
    let document: ReadableFilePreview
    let canStartReading: Bool
    let read: () -> Void
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        let navigation = UINavigationController(rootViewController: preview)
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak coordinator = context.coordinator] _ in
            coordinator?.parent.close()
        })
        close.accessibilityLabel = String(localized: "Close")
        close.accessibilityIdentifier = "file-preview-close"
        let play = UIBarButtonItem(title: String(localized: "Read Aloud"), image: UIImage(systemName: "play.fill"),
                                  primaryAction: UIAction { [weak coordinator = context.coordinator] _ in
            coordinator?.parent.read()
        })
        play.accessibilityLabel = String(localized: "Read Aloud")
        play.accessibilityIdentifier = "file-preview-read-aloud"
        play.isHidden = !canStartReading
        context.coordinator.play = play
        preview.navigationItem.rightBarButtonItems = [close, play]
        return navigation
    }

    func updateUIViewController(_ navigation: UINavigationController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.play?.isHidden = !canStartReading
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var parent: DocumentQuickLook
        var play: UIBarButtonItem?

        init(_ parent: DocumentQuickLook) { self.parent = parent }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { parent.document.files.count }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            parent.document.files[index] as NSURL
        }
    }
}
#else
private struct DocumentQuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView(frame: .zero, style: .normal)!
        preview.autostarts = false
        preview.previewItem = url as NSURL
        return preview
    }

    func updateNSView(_ preview: QLPreviewView, context: Context) {
        guard preview.previewItem?.previewItemURL != url else { return }
        preview.previewItem = url as NSURL
    }

    static func dismantleNSView(_ preview: QLPreviewView, coordinator: ()) { preview.close() }
}
#endif
