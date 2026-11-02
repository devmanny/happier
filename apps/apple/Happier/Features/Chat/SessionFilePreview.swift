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
    @Environment(BrowserModel.self) private var browser
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    /// A web link waiting for the user to choose an action.
    @State private var webLink: URL?
    @State private var browserSheet = false
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
                switch ConversationLink(url) {
                case .file(let file):
                    AppHaptics.light()
                    requested = .remote(file)
                    return .handled
                case .webPage(let page):
                    // Asks every time: open in a browser, copy, or share the full link.
                    AppHaptics.light()
                    webLink = page
                    return .handled
                case .other:
                    return .systemAction
                }
            })
            // Keep ShareLink alive while its system picker is presented. A confirmation
            // dialog dismisses its actions as soon as one is chosen.
            .popover(isPresented: linkPresented, attachmentAnchor: .point(.center), arrowEdge: .top) {
                if let url = webLink {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Link Options").font(.headline)
                            Spacer()
                            Button("Cancel", systemImage: "xmark", role: .cancel) { webLink = nil }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                        }
                        Text(url.host() ?? url.absoluteString).font(.caption).foregroundStyle(.secondary)
                        linkActions(url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(20)
                    .frame(width: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    #if os(iOS)
                    .presentationCompactAdaptation(.sheet)
                    .presentationDetents([.medium])
                    #endif
                }
            }
            .modifier(BrowserSheet(shown: $browserSheet))
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

    private var linkPresented: Binding<Bool> {
        Binding(get: { webLink != nil }, set: { if !$0 { webLink = nil } })
    }

    @ViewBuilder private func linkActions(_ url: URL) -> some View {
        Button {
            webLink = nil
            browser.show(url, forSession: sessionId)
            BrowserModel.present(openWindow: openWindow, multipleWindows: supportsMultipleWindows, sheet: $browserSheet)
        } label: {
            Label("Happier Browser", systemImage: "safari").frame(maxWidth: .infinity, alignment: .leading)
        }
        Button {
            webLink = nil
            BrowserModel.openInDefaultBrowser(url)
        } label: {
            Label("Default Browser", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity, alignment: .leading)
        }
        Button {
            MessageClipboard.copy(url.absoluteString)
            webLink = nil
            AppHaptics.success()
        } label: {
            Label("Copy Link", systemImage: "doc.on.doc").frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("copy-conversation-link")
        ShareLink(item: url) {
            Label("Share…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("share-conversation-link")
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
