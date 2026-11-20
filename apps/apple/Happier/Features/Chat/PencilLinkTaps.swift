import SwiftUI

/// Markdown text with links, drawn so an Apple Pencil tap can open them. SwiftUI's `Text` opens a
/// link for a finger but never for the Pencil (iPadOS 27.2: no link gesture joins a Pencil touch and
/// `OpenURLAction` is never called). Each link run carries its URL as a `TextAttribute`, so the
/// text's own layout says where each link was drawn, and a Pencil-only tap opens the one under it
/// through the same `OpenURLAction` a finger's tap goes through.
enum PencilLinks {
    /// A link's URL on its words, readable from the text's layout.
    struct Link: TextAttribute {
        let url: URL
    }

    /// The text split where links start and end, in order, each piece with its link (if any).
    static func pieces(_ text: AttributedString) -> [(text: AttributedString, link: URL?)] {
        text.runs[\.link].map { (AttributedString(text[$0.1]), $0.0) }
    }

    /// The same text with each link's words marked with its URL. Joined by interpolation into a key
    /// that is no literal, so nothing reaches the string catalog.
    static func text(_ text: AttributedString) -> Text {
        let pieces = pieces(text)
        var joined = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: pieces.count)
        for piece in pieces {
            let words = Text(piece.text)
            joined.appendInterpolation(piece.link.map { words.customAttribute(Link(url: $0)) } ?? words)
        }
        return Text(LocalizedStringKey(stringInterpolation: joined))
    }
}

extension MarkdownText {
    /// Inline Markdown as text; on iOS its links also open for an Apple Pencil tap.
    @ViewBuilder static func inline(_ text: AttributedString) -> some View {
        #if os(iOS)
        if text.runs.contains(where: { $0.link != nil }) {
            PencilLinks.text(text).modifier(PencilLinkTaps())
        } else {
            Text(text)
        }
        #else
        Text(text)
        #endif
    }
}

#if os(iOS)
import UIKit

private struct PencilLinkTaps: ViewModifier {
    @Environment(\.openURL) private var openURL
    /// Read by the tap, written when the layout changes (not view state: nothing redraws for it).
    @State private var drawn = DrawnLinks()

    func body(content: Content) -> some View {
        content
            .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    Color.clear.onChange(of: Self.links(layouts, in: proxy), initial: true) { _, links in drawn.links = links }
                }
            }
            .gesture(PencilTap(drawn: drawn) { openURL($0) })
    }

    /// Where each link was drawn, in the text's own coordinates.
    private static func links(_ layouts: Text.LayoutKey.Value, in proxy: GeometryProxy) -> [DrawnLinks.Link] {
        layouts.flatMap { anchored in
            let origin = proxy[anchored.origin]
            return anchored.layout.flatMap { line in
                line.compactMap { run in
                    run[PencilLinks.Link.self].map {
                        DrawnLinks.Link(frame: run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y), url: $0.url)
                    }
                }
            }
        }
    }
}

private final class DrawnLinks {
    struct Link: Equatable {
        var frame: CGRect
        var url: URL
    }

    var links: [Link] = []

    func url(at point: CGPoint) -> URL? {
        links.first { $0.frame.contains(point) }?.url
    }
}

/// A tap that only the Pencil makes, and only on a link: it never sees a finger and fails anywhere
/// else, so text selection, the long-press menu and dragging go on as before.
private struct PencilTap: UIGestureRecognizerRepresentable {
    let drawn: DrawnLinks
    let open: (URL) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(drawn: drawn, converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended, let url = drawn.url(at: context.converter.localLocation) else { return }
        open(url)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let drawn: DrawnLinks
        let converter: CoordinateSpaceConverter

        init(drawn: DrawnLinks, converter: CoordinateSpaceConverter) {
            self.drawn = drawn
            self.converter = converter
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            drawn.url(at: converter.localLocation) != nil
        }
    }
}
#endif
