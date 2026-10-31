import SwiftUI

/// An agent's logo in its brand color on a soft disc, as on the app's avatars.
struct AgentBadge: View {
    let agentId: String?
    var size: CGFloat = 26

    static let brand: [String: Color] = [
        "claude": Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255),
        "codex": Color(red: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255),
    ]

    var body: some View {
        ZStack {
            Circle().fill(.fill.tertiary)
            if let agentId {
                Image("Agents/\(agentId)").resizable().scaledToFit().padding(size * 0.2)
                    .foregroundStyle(Self.brand[agentId] ?? .primary)
            }
        }
        .frame(width: size, height: size)
    }
}
