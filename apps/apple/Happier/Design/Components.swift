import HappierKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An agent's provider logo, small, at the trailing edge of a row that names one of your agents.
struct ProviderLogo: View {
    let providerId: String
    var size: CGFloat = 18

    var body: some View {
        Image("Agents/\(providerId)")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    /// The logo for a menu item's icon. Menus draw an image at its own size (the asset is a large
    /// vector), so it is drawn at `size` first; template, so the menu tints it.
    @MainActor static func menuImage(_ providerId: String, size: CGFloat = 18) -> Image {
        let key = "\(providerId)@\(size)"
        if let cached = menuImages[key] { return cached }
        let image: Image
        #if canImport(UIKit)
        if let source = UIImage(named: "Agents/\(providerId)") {
            let rendered = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
                source.draw(in: fitted(source.size, in: size))
            }
            image = Image(uiImage: rendered.withRenderingMode(.alwaysTemplate))
        } else {
            image = Image(systemName: "cpu")
        }
        #else
        if let source = NSImage(named: "Agents/\(providerId)")?.copy() as? NSImage {
            let fit = fitted(source.size, in: size)
            source.size = fit.size
            source.isTemplate = true
            image = Image(nsImage: source)
        } else {
            image = Image(systemName: "cpu")
        }
        #endif
        menuImages[key] = image
        return image
    }

    @MainActor private static var menuImages: [String: Image] = [:]

    private static func fitted(_ natural: CGSize, in side: CGFloat) -> CGRect {
        guard natural.width > 0, natural.height > 0 else { return CGRect(x: 0, y: 0, width: side, height: side) }
        let scale = min(side / natural.width, side / natural.height)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        return CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
    }
}

/// The one agent avatar, wherever an agent is shown (session rows, the Agents section, previews,
/// notifications, the new conversation): its logo (or an agent's emoji) on a Liquid Glass disc
/// with a faint wash of its brand colour (Claude's orange, ChatGPT's classic green), so agents
/// tell apart at a glance; a neutral disc and the sparkle for a session with no agent.
struct AgentAvatar: View {
    let agentId: String?
    var size: CGFloat = 26
    /// Glass that answers to touch, for an avatar that is also a button.
    var interactive = false
    /// The project folder's color, for the disc behind the logo (instead of the brand's hint).
    var folderTint: Color? = nil
    /// An agent's own emoji, drawn on the disc in place of the logo (the disc keeps the brand's hint).
    var emoji: String? = nil

    /// Brand colours, muted: the disc is mostly the neutral glass with a hint of the brand, the
    /// logo in the brand colour itself.
    private static let brands: [String: Color] = [
        "claude": Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255),
        "codex": Color(red: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255),
    ]

    var body: some View {
        let brand = agentId.flatMap { Self.brands[$0] }
        let glass: Glass = folderTint != nil ? .regular : brand.map { .regular.tint($0.opacity(0.14)) } ?? .regular
        ZStack {
            // A little smaller than the avatar's slot, snug around the logo. A folder's color is a
            // plain fill, not a glass tint, so it stays when the window is in the background.
            Circle()
                .fill(folderTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.clear))
                .frame(width: size * 0.82, height: size * 0.82)
                .glassEffect(interactive ? glass.interactive() : glass, in: Circle())
            if let emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: size * 0.5))
            } else if let agentId {
                Image("Agents/\(agentId)")
                    .resizable()
                    .scaledToFit()
                    // White on a folder's color; otherwise the brand's own color.
                    .foregroundStyle(folderTint != nil ? AnyShapeStyle(.white) : brand.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                    .frame(width: size * 0.5, height: size * 0.5)
            } else {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A session's agent avatar.
struct SessionAvatar: View {
    let session: Session
    var size: CGFloat = 26
    /// Optional: context-menu and drag previews draw outside the app's environment, and a
    /// required store there crashes the app (the folder color is just left out).
    @Environment(HappierStore.self) private var store: HappierStore?

    var body: some View {
        AgentAvatar(agentId: session.agentId, size: size, folderTint: store?.folderColor(of: session)?.color)
    }
}

/// The mark of a session the idle cleaner put to rest (`Session.isResting`): quiet, in the secondary
/// color, never an alert. A session the user stopped keeps its usual look. Sized by the caller's font.
struct RestingMark: View {
    var body: some View {
        Image(systemName: "zzz")
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Resting"))
            .help(Text("Resting"))
    }
}

/// The small chevron at the end of a transcript line that unfolds (steps, tool groups, a tool's
/// details, the thought process): the same mark, turning down when open.
struct DisclosureChevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .accessibilityHidden(true)
    }
}

/// iMessage bubble: generous continuous corners and, on the last bubble of a run, the curved tail
/// that sweeps out of the bottom corner. Every bubble reserves `tailWidth` on its tail side so a
/// run's bubbles stay aligned whether or not they carry the tail.
struct BubbleShape: Shape {
    static let tailWidth: CGFloat = 8

    var fromUser: Bool
    var tail: Bool

    func path(in rect: CGRect) -> Path {
        var path = Self.sentBubble(width: rect.width, height: rect.height, tail: tail)
        if !fromUser {
            path = path.applying(CGAffineTransform(translationX: rect.width, y: 0).scaledBy(x: -1, y: 1))
        }
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Bubble with its tail on the right, in a `width`×`height` box (tail flush with the right edge).
    private static func sentBubble(width w: CGFloat, height h: CGFloat, tail: Bool) -> Path {
        let r = min(18, h / 2)
        let k: CGFloat = 0.47  // control-point factor for continuous-looking corners
        let right = w - tailWidth
        var p = Path()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: right - r, y: 0))
        p.addCurve(to: CGPoint(x: right, y: r), control1: CGPoint(x: right - r * k, y: 0), control2: CGPoint(x: right, y: r * k))
        if tail {
            // The tail sweeps out of the bottom-right corner to a point, then curls back into the bottom edge.
            p.addLine(to: CGPoint(x: right, y: h - 17))
            p.addCurve(to: CGPoint(x: w, y: h), control1: CGPoint(x: right, y: h - 4), control2: CGPoint(x: w - 2.5, y: h - 0.5))
            p.addCurve(to: CGPoint(x: right - 9, y: h - 4.5), control1: CGPoint(x: w - 6, y: h + 1), control2: CGPoint(x: right - 4, y: h - 1.5))
            p.addCurve(to: CGPoint(x: right - 19, y: h), control1: CGPoint(x: right - 12.5, y: h - 0.8), control2: CGPoint(x: right - 16, y: h))
        } else {
            p.addLine(to: CGPoint(x: right, y: h - r))
            p.addCurve(to: CGPoint(x: right - r, y: h), control1: CGPoint(x: right, y: h - r * k), control2: CGPoint(x: right - r * k, y: h))
        }
        p.addLine(to: CGPoint(x: r, y: h))
        p.addCurve(to: CGPoint(x: 0, y: h - r), control1: CGPoint(x: r * k, y: h), control2: CGPoint(x: 0, y: h - r * k))
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addCurve(to: CGPoint(x: r, y: 0), control1: CGPoint(x: 0, y: r * k), control2: CGPoint(x: r * k, y: 0))
        p.closeSubpath()
        return p
    }
}

extension View {
    /// iMessage text insets inside a `BubbleShape`, including the space reserved for the tail.
    func bubblePadding(fromUser: Bool) -> some View {
        padding(.vertical, 8)
            .padding(.leading, 13 + (fromUser ? 0 : BubbleShape.tailWidth))
            .padding(.trailing, 13 + (fromUser ? BubbleShape.tailWidth : 0))
    }
}

/// The three bouncing dots shown while the agent is working.
struct TypingIndicator: View {
    var body: some View {
        // Core Animation fades the dots by itself: a SwiftUI animation here redrew the whole
        // conversation every frame while the agent worked.
        PulsingDots(color: .secondary)
            .frame(width: 34, height: 8)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Color.agentBubble, in: Capsule())
            .background(alignment: .bottomLeading) {
                // iMessage's typing bubble trails off in two small circles instead of a pointed tail.
                ZStack(alignment: .bottomLeading) {
                    Circle().fill(Color.agentBubble).frame(width: 13, height: 13).offset(x: 1, y: 2)
                    Circle().fill(Color.agentBubble).frame(width: 6, height: 6).offset(x: -4, y: 8)
                }
            }
            .padding(.leading, 4)
            .padding(.bottom, 6)
            .accessibilityLabel("Agent is working")
    }
}

extension Color {
    static let userBubble = Color(red: 0, green: 122 / 255, blue: 1)

    #if os(macOS)
    static let agentBubble = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    #else
    static let agentBubble = Color(uiColor: .systemGray5)
    #endif
}

enum ChatDate {
    /// Session list time, like Messages: time today, "Yesterday", weekday, or short date.
    static func listLabel(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// A day as a heading: "Today", "Yesterday", the weekday within the last week, else the date.
    static func dayLabel(_ day: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: day, to: now).day, (0..<7).contains(days) {
            return day.formatted(.dateTime.weekday(.wide))
        }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    /// Centered separator inside a chat: "Today 10:42", "Monday 18:03", …
    static func separatorLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return String(localized: "Today \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday \(time)") }
        return "\(listLabel(date)) \(time)"
    }
}

/// The way out of a sheet whose choices apply at once (Account, Relay, Notifications, Background,
/// the model picker…): the system's close button (the glass X, placed and localized by it).
/// Sheets that pick something keep a Cancel button.
struct SheetCloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button(role: .close) {
            AppHaptics.light()
            dismiss()
        }
    }
}

/// The one style for a control the system has no style for (a transcript line that unfolds, a
/// thumbnail, the agent avatar as a button): the label as drawn, dimmed while pressed, and the
/// iPad's hover under the Apple Pencil or a pointer. Everything else uses a system style
/// (`.borderless`, `.glass`, the row style inside a `List`), which already has both.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            #if os(iOS)
            // The whole button lights up (a full row, not just its text and icon), a little
            // wider than its frame, like a system list row under the pointer.
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 10, style: .continuous).inset(by: -6))
            .hoverEffect(.highlight)
            #endif
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

extension View {
    /// A `List` row of the sidebar: the system's selection does not light the row up under the
    /// Apple Pencil or a pointer on iPad (observed on iPadOS 26), so the row gets the highlight itself.
    func pointerHoverRow(cornerRadius: CGFloat = 12) -> some View {
        #if os(iOS)
        contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hoverEffect(.highlight)
        #else
        self
        #endif
    }
}

extension View {
    /// Glass buttons don't light up under the Apple Pencil or a pointer on iPad by themselves; this
    /// gives them the system's lift, as Apple recommends for controls that lack it.
    @ViewBuilder
    func glassHover() -> some View {
        #if os(iOS)
        // The glass is a capsule (or a circle, its square case): the lift takes its shape.
        contentShape(.hoverEffect, Capsule())
            .hoverEffect(.lift)
        #else
        self
        #endif
    }
}

extension AccountSettings.FolderColor {
    /// The folder's color: vivid, and readable under white text (your bubbles, the avatar's
    /// disc, the picker's dots).
    var color: Color {
        let rgb = vivid
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    var name: LocalizedStringKey {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .teal: "Teal"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .pink: "Pink"
        case .gray: "Gray"
        }
    }
}

extension HappierStore {
    /// The color the user gave this session's project folder, if any.
    func folderColor(of session: Session?) -> AccountSettings.FolderColor? {
        guard let path = session?.path else { return nil }
        return accountSettings?.folderColor(for: path)
    }

    func setFolderColor(_ color: AccountSettings.FolderColor?, forPath path: String) {
        Task { await updateAccountSettings { $0.delta(folderColor: color, for: path) } }
    }
}

/// "Folder Color": the project's color for every session in it, synced across devices.
struct FolderColorMenu: View {
    let path: String
    let current: AccountSettings.FolderColor?
    let choose: (AccountSettings.FolderColor?) -> Void

    var body: some View {
        Menu("Folder Color", systemImage: "circle.lefthalf.filled") {
            Picker("Folder Color", selection: Binding(get: { current }, set: { choose($0) })) {
                Text("None").tag(AccountSettings.FolderColor?.none)
                ForEach(AccountSettings.FolderColor.allCases, id: \.self) { color in
                    Label { Text(color.name) } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(color.color, color.color)
                    }
                    .tag(Optional(color))
                }
            }
            .pickerStyle(.inline)
        }
    }
}

extension EnvironmentValues {
    /// The color of your own message bubbles, and of what answers for you (send, reply options,
    /// read aloud): the app's blue, or the conversation's project folder color, set once by the
    /// conversation.
    @Entry var userBubbleColor: Color = .userBubble
}

/// The project folder's color as a barely tinted ground under the conversation and, in a window
/// of its own, a soft glow along the inside of the window's edges, so it tells its project at a
/// glance. No glow in the main window, where it would frame only one pane. Static: nothing to
/// animate.
struct FolderWash: View {
    let color: Color?
    @Environment(\.inSessionWindow) private var inSessionWindow

    var body: some View {
        if let color {
            ZStack {
                color.opacity(0.03)
                if inSessionWindow {
                    Rectangle()
                        .strokeBorder(color.opacity(0.32), lineWidth: 10)
                        .blur(radius: 26)
                }
            }
            .clipped()
            // Not sideways: on the Mac that would run the glow's edges under the sidebar.
            .ignoresSafeArea(edges: .vertical)
            .allowsHitTesting(false)
        }
    }
}
