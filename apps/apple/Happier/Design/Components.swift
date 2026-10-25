import HappierKit
import SwiftUI

/// The one agent avatar, wherever an agent is shown (session rows, previews, notifications, the
/// new conversation): its logo on a Liquid Glass disc with a faint wash of its brand colour
/// (Claude's orange, ChatGPT's classic green), so agents tell apart at a glance; a neutral disc
/// and the sparkle for a session with no agent.
struct AgentAvatar: View {
    let agentId: String?
    var size: CGFloat = 26
    /// Glass that answers to touch, for an avatar that is also a button.
    var interactive = false

    /// Brand colours, muted: the disc is mostly the neutral glass with a hint of the brand, the
    /// logo in the brand colour itself.
    private static let brands: [String: Color] = [
        "claude": Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255),
        "codex": Color(red: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255),
    ]

    var body: some View {
        let brand = agentId.flatMap { Self.brands[$0] }
        let glass: Glass = brand.map { .regular.tint($0.opacity(0.14)) } ?? .regular
        ZStack {
            // A little smaller than the avatar's slot, snug around the logo.
            Circle()
                .fill(.clear)
                .frame(width: size * 0.82, height: size * 0.82)
                .glassEffect(interactive ? glass.interactive() : glass, in: Circle())
            if let agentId {
                Image("Agents/\(agentId)")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(brand.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
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

    var body: some View {
        AgentAvatar(agentId: session.agentId, size: size)
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
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 8, height: 8)
                    .phaseAnimator([0.35, 1.0]) { dot, phase in
                        dot.opacity(phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.5).delay(Double(index) * 0.18)
                    }
            }
        }
        .foregroundStyle(.secondary)
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
/// the model picker…): the glass X, leading. Sheets that pick something keep a Cancel button.
struct SheetCloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button("Close", systemImage: "xmark") { dismiss() }
    }
}
