import HappierKit
import QuickLook
import SwiftUI

extension EnvironmentValues {
    /// One system preview owner for a conversation's attachments and Markdown file links.
    @Entry var openSessionFilePreview: ((URL) -> Void)? = nil
}

struct SessionFilePreview: ViewModifier {
    private enum Request: Equatable {
        case remote(RemoteFileLink)
        case local(URL)
    }

    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var lookingAt: URL?
    @State private var previewFiles: [URL] = []
    @State private var document: ReadableFilePreview?
    @State private var requested: Request?
    @State private var progress: Double = 0
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .environment(\.openSessionFilePreview) { requested = .local($0) }
            .environment(\.openURL, OpenURLAction { url in
                guard let file = RemoteFileLink(url: url) else { return .systemAction }
                AppHaptics.light()
                requested = .remote(file)
                return .handled
            })
            .quickLookPreview($lookingAt, in: previewFiles)
            .sheet(item: $document) { document in
                ReadableFilePreviewView(document: document)
            }
            .overlay(alignment: .top) {
                if case .remote(let file)? = requested {
                    HStack(spacing: 10) {
                        ProgressView(value: progress).frame(width: 48)
                        Text("Opening \(file.name)…")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(12)
                    .glassEffect()
                    .padding()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("session-file-download")
                    .allowsHitTesting(false)
                }
            }
            .task(id: requested) {
                guard let request = requested else { return }
                progress = 0
                defer {
                    if requested == request { requested = nil }
                }
                do {
                    let url: URL
                    switch request {
                    case .local(let localURL): url = localURL
                    case .remote(let file):
                        url = try await store.attachmentFile(MessageAttachment(name: file.name, path: file.path),
                                                             in: sessionId, refresh: true) { fraction in
                            if requested == request { progress = fraction }
                        }
                    }
                    try Task.checkCancellation()
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try Self.preparePreview(url)
                    }.value
                    try Task.checkCancellation()
                    if let prepared {
                        document = prepared
                    } else {
                        previewFiles = [url]
                        lookingAt = url
                    }
                    AppHaptics.success()
                } catch is CancellationError {
                    // A different file or conversation replaced this request.
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                    AppHaptics.error()
                }
            }
            .alert("Can't Open the File", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    /// Keep the source alongside its formatted copy: Quick Look displays either, and the
    /// shared message reader speaks the Markdown without reading HTML or formatting symbols.
    nonisolated private static func preparePreview(_ url: URL) throws -> ReadableFilePreview? {
        guard MarkdownFilePreview.supports(url) else { return nil }
        var encoding = String.Encoding.utf8
        guard let markdown = try? String(contentsOf: url, usedEncoding: &encoding) else { return nil }
        let html = MarkdownFilePreview.html(markdown: markdown, title: url.lastPathComponent)
        let preview = url.deletingPathExtension().appendingPathExtension("preview.html")
        try Data(html.utf8).write(to: preview, options: .atomic)
        return ReadableFilePreview(original: url, formatted: preview, markdown: markdown,
                                   canReadAloud: !SpokenText.from(markdown: markdown).isEmpty)
    }
}
