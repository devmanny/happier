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
    /// The handlers the conversation's rows read; made once, so the environment they read doesn't
    /// change on every redraw (a new closure or `OpenURLAction` there re-ran every row with a link).
    @State private var routes = Routes()

    @MainActor
    private final class Routes {
        var request: (Request) -> Void = { _ in }
        var webPage: (URL) -> Void = { _ in }
        lazy var openFile: (URL) -> Void = { [unowned self] url in self.request(.local(url)) }
        lazy var openURL = OpenURLAction { [unowned self] url in
            switch ConversationLink(url) {
            case .file(let file):
                AppHaptics.light()
                self.request(.remote(file))
                return .handled
            case .webPage(let page):
                // Asks every time: open in a browser, copy, or share the full link.
                AppHaptics.light()
                self.webPage(page)
                return .handled
            case .other:
                return .systemAction
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openSessionFilePreview, routes.openFile)
            .environment(\.openURL, routes.openURL)
            .onAppear {
                routes.request = { requested = $0 }
                #if os(macOS)
                // The Mac's own menu, where the click was.
                routes.webPage = { url in
                    LinkMenu.show(url, openInHappier: { openInHappier(url) }, copy: { copy(url) })
                }
                #else
                routes.webPage = { webLink = $0 }
                #endif
            }
            #if os(iOS)
            // The system's action sheet (a popover on iPad), titled with the link's site.
            .confirmationDialog(webLink.map(Self.site) ?? "", isPresented: linkPresented, titleVisibility: .visible,
                                presenting: webLink) { url in
                Button("Open in Happier") { openInHappier(url) }
                Button("Open in Browser") { BrowserModel.openInDefaultBrowser(url) }
                Button("Copy Link") { copy(url) }
                    .accessibilityIdentifier("copy-conversation-link")
                // The share sheet comes once this dialog has gone: shown from it, it closed with it.
                Button("Share…") { SystemShare.present(url) }
                    .accessibilityIdentifier("share-conversation-link")
                Button("Cancel", role: .cancel) {}
            }
            #endif
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

    private func openInHappier(_ url: URL) {
        browser.show(url, forSession: sessionId)
        BrowserModel.present(openWindow: openWindow, multipleWindows: supportsMultipleWindows, sheet: $browserSheet)
    }

    private func copy(_ url: URL) {
        MessageClipboard.copy(url.absoluteString)
        AppHaptics.success()
    }

    static func site(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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
