import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The session list's filter button icon. A toolbar item is drawn from its label's image and text
/// only (an overlay on it never shows), and the toolbar has no badge without a number, so when a
/// filter is chosen the dot is part of the image itself: the symbol and a red dot composed into one
/// image in its original colors, made again when the appearance (light or dark) or the tint
/// changes. Without a dot it's the plain template symbol, as before.
struct FilterButtonIcon: View {
    /// The filter is on (filled symbol).
    let filled: Bool
    /// A filter other than the usual list is chosen.
    let dot: Bool
    /// The symbol's color when the filter is on; nil for the toolbar's own.
    let tint: Color?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment

    private var symbol: String {
        filled ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
    }

    var body: some View {
        if dot {
            Self.composed(symbol: symbol, color: tint?.resolve(in: environment).cgColor ?? Self.labelColor(colorScheme))
                .renderingMode(.original)
                // Made again when the appearance changes.
                .id(colorScheme)
        } else {
            Image(systemName: symbol)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
        }
    }

    private static func labelColor(_ scheme: ColorScheme) -> CGColor {
        #if os(iOS)
        UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)).cgColor
        #else
        (scheme == .dark ? NSColor.white : NSColor.black).cgColor
        #endif
    }

    /// The symbol at toolbar size in `color`, with a red dot at its top right.
    static func composed(symbol: String, color: CGColor) -> Image {
        let dotDiameter: CGFloat = 7
        #if os(iOS)
        // The toolbar's own size for a symbol (body text style, large scale), and the image exactly
        // the glyph's size with the dot inside its corner: a bigger canvas was scaled down to fit.
        let configuration = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
        guard let base = UIImage(systemName: symbol, withConfiguration: configuration)?
            .withTintColor(UIColor(cgColor: color), renderingMode: .alwaysOriginal) else { return Image(systemName: symbol) }
        let size = base.size
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            base.draw(at: .zero)
            UIColor.systemRed.setFill()
            UIBezierPath(ovalIn: CGRect(x: size.width - dotDiameter, y: 0, width: dotDiameter, height: dotDiameter)).fill()
        }
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
        #else
        let configuration = NSImage.SymbolConfiguration(textStyle: .body, scale: .large)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: color) ?? .labelColor]))
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return Image(systemName: symbol) }
        let size = base.size
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: size.width - dotDiameter, y: size.height - dotDiameter, width: dotDiameter, height: dotDiameter)).fill()
            return true
        }
        return Image(nsImage: image)
        #endif
    }
}
