import HappierKit
import SwiftUI
#if os(iOS)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#endif

/// Lets the composer insert a file mention where the cursor is, and remembers which tokens came
/// from the picker so they stay pills when the text is rebuilt.
@MainActor
final class ComposerEditor {
    fileprivate weak var insertion: MentionInserting?
    fileprivate(set) var knownMentions: Set<String> = []

    /// Puts a pill for `path` at the cursor; false when the field isn't on screen.
    func insertMention(_ path: String) -> Bool {
        knownMentions.insert(path)
        guard let insertion else { return false }
        insertion.insertMention(path)
        return true
    }

    /// Turns the `@word` being typed into a pill for `path` (a picked suggestion).
    func completeMention(_ path: String) {
        knownMentions.insert(path)
        insertion?.completeMention(path)
    }
}

@MainActor
fileprivate protocol MentionInserting: AnyObject {
    func insertMention(_ path: String)
    func completeMention(_ path: String)
}

// MARK: - Mention pills

/// A file mention inside the text: one character that draws as a green pill with `@name`, so a
/// single delete removes it and text flows around it.
final class MentionAttachment: NSTextAttachment {
    let path: String

    init(path: String, font: PlatformFont) {
        self.path = path
        super.init(data: nil, ofType: nil)
        let pill = Self.render("@" + FileMention.displayName(path), font: font)
        image = pill
        // Centred on the text's x-height, like an inline badge.
        bounds = CGRect(x: 0, y: (font.capHeight - pill.size.height) / 2, width: pill.size.width, height: pill.size.height)
    }

    required init?(coder: NSCoder) { fatalError("not coded") }

    static let fill = PlatformColor(red: 0.16, green: 0.6, blue: 0.33, alpha: 1)

    private static func render(_ title: String, font: PlatformFont) -> PlatformImage {
        let titleFont = PlatformFont.systemFont(ofSize: font.pointSize * 0.86, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: PlatformColor.white]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let height = ceil(max(textSize.height + 4, font.capHeight + 10))
        let size = CGSize(width: ceil(textSize.width + 14), height: height)
        let origin = CGPoint(x: 7, y: (height - textSize.height) / 2)
        #if os(iOS)
        return UIGraphicsImageRenderer(size: size).image { _ in
            fill.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 2).fill()
            (title as NSString).draw(at: origin, withAttributes: attributes)
        }
        #else
        return NSImage(size: size, flipped: true) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            (title as NSString).draw(at: origin, withAttributes: attributes)
            return true
        }
        #endif
    }
}

/// Text ↔ attributed text with pills: mentions become `MentionAttachment`s and back to tokens.
enum MentionAttributed {
    static func attributed(_ text: String, known: Set<String>, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = attributes[.font] as? PlatformFont ?? .systemFont(ofSize: 17)
        for segment in MentionText.segments(in: text, known: known) {
            switch segment {
            case .text(let plain):
                result.append(NSAttributedString(string: plain, attributes: attributes))
            case .mention(let path):
                let pill = NSMutableAttributedString(attachment: MentionAttachment(path: path, font: font))
                pill.addAttributes(attributes, range: NSRange(location: 0, length: pill.length))
                result.append(pill)
            }
        }
        return result
    }

    static func string(from attributed: NSAttributedString) -> String {
        var segments: [MentionText.Segment] = []
        let whole = attributed.string as NSString
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let mention = value as? MentionAttachment {
                segments.append(.mention(mention.path))
            } else {
                let plain = whole.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
                if !plain.isEmpty { segments.append(.text(plain)) }
            }
        }
        return MentionText.string(from: segments)
    }
}

// MARK: - iOS

#if os(iOS)
/// The composer's text field: a text view so file mentions can sit in the text as pills. Return
/// sends (Shift-Return on a keyboard breaks the line), it grows to ten lines and then scrolls, and
/// pasting a copied image attaches it.
struct ComposerTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    let editor: ComposerEditor
    let onSubmit: () -> Void
    let onPasteImages: ([AttachmentDraft]) -> Void
    /// The `@word` being typed (without the `@`), or nil: drives the file suggestions.
    var onMentionQuery: (String?) -> Void = { _ in }

    private static let maxLines: CGFloat = 10

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        // Apple Pencil: handwriting starts only on the field itself, not in the margin around it,
        // which covers the composer's buttons and swallowed their taps.
        view.addInteraction(UIScribbleInteraction(delegate: context.coordinator))
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.returnKeyType = .send
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.placeholder = placeholder
        editor.insertion = context.coordinator
        context.coordinator.apply(text, to: view)
        return view
    }

    func updateUIView(_ view: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        editor.insertion = context.coordinator
        view.placeholder = placeholder
        if text != context.coordinator.lastText { context.coordinator.apply(text, to: view) }
        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        // An ideal-size query (no width) is answered with the width it has.
        let width = proposal.width ?? (uiView.bounds.width > 0 ? uiView.bounds.width : 320)
        let lineHeight = uiView.font?.lineHeight ?? 22
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let limit = lineHeight * Self.maxLines
        let scrolls = fitting > limit + 1
        if uiView.isScrollEnabled != scrolls {
            DispatchQueue.main.async { uiView.isScrollEnabled = scrolls }
        }
        return CGSize(width: width, height: ceil(min(max(fitting, lineHeight), limit)))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIScribbleInteractionDelegate, MentionInserting {
        var parent: ComposerTextField

        func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
            interaction.view?.bounds.contains(location) ?? false
        }
        /// The text as this field last reported it, to tell its own edits from outside ones.
        var lastText = ""

        init(_ parent: ComposerTextField) {
            self.parent = parent
        }

        weak var view: ComposerUITextView?

        var baseAttributes: [NSAttributedString.Key: Any] {
            [.font: view?.font ?? UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
        }

        /// Text set from outside (dictation, a restored draft, a sent message): rebuilt with its
        /// pills, the cursor at the end.
        func apply(_ text: String, to view: ComposerUITextView) {
            self.view = view
            lastText = text
            view.attributedText = MentionAttributed.attributed(text, known: parent.editor.knownMentions, attributes: baseAttributes)
            view.typingAttributes = baseAttributes
            view.selectedRange = NSRange(location: view.attributedText.length, length: 0)
            view.refreshPlaceholder()
            // Long text opens at its end, where the cursor is.
            DispatchQueue.main.async { view.scrollRangeToVisible(view.selectedRange) }
        }

        /// Where the `@word` being typed sits, while there is one.
        private var queryRange: NSRange?
        private var lastQuery: String?

        func insertMention(_ path: String) {
            replace(view?.selectedRange, withMention: path)
        }

        func completeMention(_ path: String) {
            replace(queryRange ?? view?.selectedRange, withMention: path)
        }

        private func updateQuery(_ view: UITextView) {
            let selection = view.selectedRange
            let found = selection.length == 0 ? MentionText.typingQuery(in: view.attributedText.string as NSString, caret: selection.location) : nil
            queryRange = found?.range
            guard found?.query != lastQuery else { return }
            lastQuery = found?.query
            let report = parent.onMentionQuery
            // Not during a view update.
            Task { @MainActor in report(found?.query) }
        }

        private func replace(_ target: NSRange?, withMention path: String) {
            guard let view, let range = target else { return }
            let font = view.font ?? .preferredFont(forTextStyle: .body)
            let pill = NSMutableAttributedString(attachment: MentionAttachment(path: path, font: font))
            pill.addAttributes(baseAttributes, range: NSRange(location: 0, length: pill.length))
            pill.append(NSAttributedString(string: " ", attributes: baseAttributes))
            view.textStorage.replaceCharacters(in: range, with: pill)
            view.selectedRange = NSRange(location: range.location + pill.length, length: 0)
            view.typingAttributes = baseAttributes
            textViewDidChange(view)
            parent.isFocused = true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? ComposerUITextView else { return }
            self.view = view
            let text = MentionAttributed.string(from: view.attributedText)
            lastText = text
            view.refreshPlaceholder()
            view.invalidateIntrinsicContentSize()
            if parent.text != text { parent.text = text }
            updateQuery(view)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Text typed after a pill shouldn't pick up its attachment styling.
            textView.typingAttributes = baseAttributes
            updateQuery(textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", (textView as? ComposerUITextView)?.insertingNewline != true else { return true }
            parent.onSubmit()
            return false
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

final class ComposerUITextView: UITextView {
    weak var coordinator: ComposerTextField.Coordinator?
    /// Set while Shift-Return inserts a line break, which Return alone would send.
    fileprivate(set) var insertingNewline = false

    var placeholder = "" {
        didSet { placeholderLabel.text = placeholder }
    }

    private lazy var placeholderLabel: UILabel = {
        let label = UILabel()
        label.textColor = .placeholderText
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        addSubview(label)
        return label
    }()

    func refreshPlaceholder() {
        placeholderLabel.isHidden = !attributedText.string.isEmpty
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = textContainerInset
        placeholderLabel.frame = CGRect(x: inset.left, y: inset.top, width: bounds.width - inset.left - inset.right,
                                        height: font?.lineHeight ?? 22)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key, key.keyCode == .keyboardReturnOrEnter, key.modifierFlags.contains(.shift) {
            insertingNewline = true
            insertText("\n")
            insertingNewline = false
            return
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: Paste and copy

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    /// A copied image (and no text) becomes an attachment, like Messages.
    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if board.hasImages, !board.hasStrings {
            let drafts = (board.images ?? []).enumerated().compactMap { index, image in
                image.jpegData(compressionQuality: 0.85).map { AttachmentLoader.photo($0, index: index) }
            }
            if !drafts.isEmpty {
                coordinator?.parent.onPasteImages(drafts)
                return
            }
        }
        super.paste(sender)
    }

    /// Copies pills as their `@path` tokens, so they paste anywhere as text.
    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return super.copy(sender) }
        UIPasteboard.general.string = MentionAttributed.string(from: attributedText.attributedSubstring(from: selectedRange))
    }

    override func cut(_ sender: Any?) {
        guard selectedRange.length > 0 else { return super.cut(sender) }
        copy(sender)
        let range = selectedRange
        textStorage.replaceCharacters(in: range, with: "")
        selectedRange = NSRange(location: range.location, length: 0)
        delegate?.textViewDidChange?(self)
    }
}
#endif

// MARK: - macOS

#if os(macOS)
/// The composer's text field on the Mac (see the iOS one): Return sends, Shift- or Option-Return
/// breaks the line; ⌘V of files and images is handled by the composer's `PasteShortcut`.
struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    let editor: ComposerEditor
    let onSubmit: () -> Void
    let onPasteImages: ([AttachmentDraft]) -> Void
    var onMentionQuery: (String?) -> Void = { _ in }

    private static let maxLines: CGFloat = 10

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.placeholder = placeholder
        let scroll = ComposerScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        context.coordinator.textView = textView
        editor.insertion = context.coordinator
        context.coordinator.apply(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        editor.insertion = context.coordinator
        guard let textView = context.coordinator.textView else { return }
        textView.placeholder = placeholder
        if text != context.coordinator.lastText { context.coordinator.apply(text) }
        let isFirst = textView.window?.firstResponder === textView
        if isFocused, !isFirst {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        } else if !isFocused, isFirst {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(nil) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = context.coordinator.textView, let storage = textView.textStorage else { return nil }
        // SwiftUI also asks with no width (an ideal-size query): answer with the width it has.
        // Measuring never touches the live view; resizing it here wrapped the text short at random.
        let width = proposal.width ?? max(nsView.frame.width, 1)
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let used = Self.height(of: storage, width: width)
        return CGSize(width: width, height: ceil(min(max(used, lineHeight), lineHeight * Self.maxLines)))
    }

    /// The text's height at `width`, laid out on a copy.
    private static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let container = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).height
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, MentionInserting {
        var parent: ComposerTextField
        var lastText = ""
        weak var textView: ComposerNSTextView?

        init(_ parent: ComposerTextField) {
            self.parent = parent
        }

        var baseAttributes: [NSAttributedString.Key: Any] {
            [.font: textView?.font ?? NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor]
        }

        func apply(_ text: String) {
            guard let textView else { return }
            lastText = text
            textView.textStorage?.setAttributedString(
                MentionAttributed.attributed(text, known: parent.editor.knownMentions, attributes: baseAttributes))
            textView.typingAttributes = baseAttributes
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            textView.needsDisplay = true
        }

        private var queryRange: NSRange?
        private var lastQuery: String?

        func insertMention(_ path: String) {
            replace(textView?.selectedRange(), withMention: path)
        }

        func completeMention(_ path: String) {
            replace(queryRange ?? textView?.selectedRange(), withMention: path)
        }

        private func updateQuery() {
            guard let textView else { return }
            let selection = textView.selectedRange()
            let found = selection.length == 0 ? MentionText.typingQuery(in: textView.string as NSString, caret: selection.location) : nil
            queryRange = found?.range
            guard found?.query != lastQuery else { return }
            lastQuery = found?.query
            let report = parent.onMentionQuery
            Task { @MainActor in report(found?.query) }
        }

        private func replace(_ target: NSRange?, withMention path: String) {
            guard let textView, let storage = textView.textStorage, let range = target else { return }
            let font = textView.font ?? .preferredFont(forTextStyle: .body)
            let pill = NSMutableAttributedString(attachment: MentionAttachment(path: path, font: font))
            pill.addAttributes(baseAttributes, range: NSRange(location: 0, length: pill.length))
            pill.append(NSAttributedString(string: " ", attributes: baseAttributes))
            storage.replaceCharacters(in: range, with: pill)
            textView.setSelectedRange(NSRange(location: range.location + pill.length, length: 0))
            textView.typingAttributes = baseAttributes
            changed()
            parent.isFocused = true
        }

        func textDidChange(_ notification: Notification) { changed() }

        private func changed() {
            guard let textView, let storage = textView.textStorage else { return }
            let text = MentionAttributed.string(from: storage)
            lastText = text
            textView.needsDisplay = true
            if parent.text != text { parent.text = text }
            updateQuery()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.typingAttributes = baseAttributes
            updateQuery()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

/// Keeps the text exactly as wide as what the field shows: left to autoresizing, the text view
/// kept an earlier, narrower width and wrapped the text short of the edge.
final class ComposerScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView else { return }
        let width = contentSize.width
        if abs(textView.frame.width - width) > 0.5 {
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { (delegate as? ComposerTextField.Coordinator)?.textDidBeginEditing(Notification(name: NSText.didBeginEditingNotification)) }
        return became
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: [
            .font: font ?? NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.placeholderTextColor,
        ])
    }

    /// Copies pills as their `@path` tokens.
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MentionAttributed.string(from: storage.attributedSubstring(from: range)), forType: .string)
    }
}
#endif
