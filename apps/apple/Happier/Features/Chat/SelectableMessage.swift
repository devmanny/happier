import HappierKit
import SwiftUI

extension EnvironmentValues {
    /// The message whose text is open for selecting ("Select Text"), if any (set by the chat).
    @Entry var textSelectingId: String? = nil
    /// Message text can be selected (only while "Select Text" is on, on every platform).
    @Entry var messageTextSelectable = false
}

extension View {
    /// A message bubble's content, swapped for selectable text while "Select Text" is on for it:
    /// on iOS a text view (SwiftUI only selects a whole Text there, not a few words), on the Mac
    /// the same Markdown with selection on. A dashed outline marks the mode.
    func selectableMessage(id: String, markdown: String, fromUser: Bool, shape: BubbleShape) -> some View {
        modifier(SelectableMessageModifier(id: id, markdown: markdown, fromUser: fromUser, shape: shape))
    }

    /// `.textSelection` on or off (its two settings are different types).
    @ViewBuilder func textSelectable(_ on: Bool) -> some View {
        if on { textSelection(.enabled) } else { textSelection(.disabled) }
    }
}

private struct SelectableMessageModifier: ViewModifier {
    let id: String
    let markdown: String
    let fromUser: Bool
    let shape: BubbleShape
    @Environment(\.textSelectingId) private var selectingId
    @Environment(\.chatRowActions) private var rowActions

    func body(content: Content) -> some View {
        if selectingId == id {
            selectable
                .bubblePadding(fromUser: fromUser)
                .background(fromUser ? Color.userBubble : Color.agentBubble, in: shape)
                .overlay {
                    shape.stroke(fromUser ? Color.white.opacity(0.9) : Color.userBubble,
                                 style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowActions?.reportTextSelectionFrame($0) }
                .transition(.opacity)
        } else {
            content
        }
    }

    @ViewBuilder private var selectable: some View {
        #if os(iOS)
        SelectableMessageText(markdown: markdown, color: fromUser ? .white : .label)
        #else
        MarkdownText(markdown)
            .environment(\.messageTextSelectable, true)
            .foregroundStyle(fromUser ? Color.white : Color.primary)
            .environment(\.colorScheme, fromUser ? .dark : .light)
        #endif
    }
}

#if os(iOS)
import UIKit

/// The message as a read-only text view: double-tap or drag the handles to pick words, with the
/// system's Copy, Look Up and Share.
private struct SelectableMessageText: UIViewRepresentable {
    let markdown: String
    let color: UIColor
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.linkTextAttributes = [.foregroundColor: color, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.attributedText = Self.attributed(markdown, color: color)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openURL = openURL
        let text = Self.attributed(markdown, color: color)
        if view.attributedText.string != text.string { view.attributedText = text }
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: OpenURLAction

        init(openURL: OpenURLAction) { self.openURL = openURL }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.openURL(url) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(width, ceil(fitting.width)), height: ceil(fitting.height))
    }

    /// Markdown to styled text: bold, italic, code and links inline; code blocks monospaced; quotes
    /// and tables as plain lines.
    static func attributed(_ markdown: String, color: UIColor) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let base: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: color]
        let result = NSMutableAttributedString()
        func paragraph(_ text: NSAttributedString) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n", attributes: base)) }
            result.append(text)
        }
        func inline(_ text: String, color: UIColor) -> NSAttributedString {
            let parsed = MarkdownText.attributed(text)
            let out = NSMutableAttributedString()
            for run in parsed.runs {
                var attributes: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: color]
                if let intent = run.inlinePresentationIntent {
                    var traits: UIFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                    if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                    if intent.contains(.code) {
                        attributes[.font] = UIFont.monospacedSystemFont(ofSize: body.pointSize * 0.92, weight: .regular)
                    } else if !traits.isEmpty, let descriptor = body.fontDescriptor.withSymbolicTraits(traits) {
                        attributes[.font] = UIFont(descriptor: descriptor, size: body.pointSize)
                    }
                }
                if let link = run.link { attributes[.link] = link }
                out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            return out
        }
        for segment in MarkdownSegments.parse(markdown) {
            switch segment {
            case .prose(let text):
                paragraph(inline(text, color: color))
            case .code(let code, _):
                paragraph(NSAttributedString(string: code, attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: body.pointSize * 0.9, weight: .regular), .foregroundColor: color,
                ]))
            case .quote(let inner):
                let text = inner.compactMap { if case .prose(let p) = $0 { p } else { nil } }.joined(separator: "\n")
                paragraph(inline(text, color: color.withAlphaComponent(0.75)))
            case .table(let table):
                let lines = ([table.headers] + table.rows).map { $0.joined(separator: "  ·  ") }
                paragraph(NSAttributedString(string: lines.joined(separator: "\n"), attributes: base))
            case .options(let items):
                paragraph(NSAttributedString(string: items.map { "• \($0)" }.joined(separator: "\n"), attributes: base))
            }
        }
        return result
    }
}
#endif
