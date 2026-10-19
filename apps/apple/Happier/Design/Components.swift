import HappierKit
import SwiftUI

/// Gradient avatar (same image choice as the official app) with the agent logo as a badge.
struct SessionAvatar: View {
    let session: Session
    var size: CGFloat = 52

    var body: some View {
        let index = AvatarHash.gradientIndex(session.avatarId) + 1
        Image(String(format: "Gradients/%02d", index))
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                if let agent = session.agentId {
                    AgentBadge(agentId: agent, size: size * 0.42)
                        .offset(x: size * 0.04, y: size * 0.04)
                }
            }
            .accessibilityHidden(true)
    }
}

struct AgentBadge: View {
    let agentId: String
    var size: CGFloat = 20

    var body: some View {
        Image("Agents/\(agentId)")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(.background, in: Circle())
            .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// Rounded bubble with the iMessage tail on the last bubble of a run.
struct BubbleShape: Shape {
    var fromUser: Bool
    var tail: Bool

    func path(in rect: CGRect) -> Path {
        let body = Path(roundedRect: rect, cornerRadius: 18, style: .continuous)
        guard tail else { return body }
        var t = Path()
        let x = rect.maxX, y = rect.maxY
        t.move(to: CGPoint(x: x - 10, y: y - 16))
        t.addCurve(to: CGPoint(x: x + 5, y: y), control1: CGPoint(x: x - 8, y: y - 5), control2: CGPoint(x: x - 1, y: y - 0.5))
        t.addCurve(to: CGPoint(x: x - 16, y: y - 5), control1: CGPoint(x: x - 5, y: y + 1.5), control2: CGPoint(x: x - 11, y: y - 1.5))
        t.closeSubpath()
        if !fromUser {
            t = t.applying(CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1))
        }
        return body.union(t)
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
