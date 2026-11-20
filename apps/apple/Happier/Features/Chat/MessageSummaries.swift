import FoundationModels
import HappierKit
import OSLog
import SwiftUI

/// The TL;DRs written for long agent messages (`MessageSummary`), by Apple's on-device model: free,
/// private, and written once per message; toggling back and forth only shows the one already made.
/// Kept while the app runs.
@Observable @MainActor
final class MessageSummaries {
    static let shared = MessageSummaries()

    private(set) var summaries: [String: String] = [:]
    private(set) var writing: Set<String> = []
    private let log = Logger(subsystem: "dev.happier.apple", category: "tldr")

    /// Apple Intelligence is on and its model is ready; without it, no TL;DR is offered.
    var available: Bool { SystemLanguageModel.default.isAvailable }

    /// The message's TL;DR, written the first time; nil when the model couldn't (reported).
    func summary(id: String, text: String) async -> String? {
        if let done = summaries[id] { return done }
        guard !writing.contains(id) else { return nil }
        writing.insert(id)
        defer { writing.remove(id) }
        do {
            let session = LanguageModelSession(instructions: MessageSummary.instructions)
            let answer = try await session.respond(to: MessageSummary.input(text)).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return nil }
            summaries[id] = answer
            return answer
        } catch {
            log.error("TL;DR failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// A long agent message's TL;DR button, floating on its top corner like a Messages tapback: the
/// first tap writes the TL;DR and shows it in the bubble, the next shows the whole message again,
/// and the next the TL;DR already written.
struct TLDRButton: View {
    let id: String
    let text: String
    @Binding var showsSummary: Bool
    @State private var failed = false
    private var summaries: MessageSummaries { .shared }

    var body: some View {
        let writing = summaries.writing.contains(id)
        Button(action: toggle) {
            Group {
                if writing {
                    ProgressView().controlSize(.mini)
                } else if failed {
                    Image(systemName: "exclamationmark")
                        .font(.caption.weight(.bold))
                } else {
                    Text(verbatim: "TL;DR")
                        .font(.caption2.weight(.heavy))
                }
            }
            .foregroundStyle(showsSummary ? Color.white : Color.primary)
            .frame(minWidth: 34, minHeight: 24)
            .padding(.horizontal, 6)
            .glassEffect(showsSummary ? .regular.tint(.userBubble).interactive() : .regular.interactive(), in: Capsule())
            .contentShape(Capsule().inset(by: -10))
        }
        .buttonStyle(.plain)
        .disabled(writing)
        .help(Text(failed ? "Couldn't write the TL;DR. Try again." : showsSummary ? "Show Whole Message" : "TL;DR"))
        .accessibilityLabel(Text(failed ? "Couldn't write the TL;DR. Try again." : showsSummary ? "Show Whole Message" : "TL;DR"))
        .accessibilityIdentifier("message-tldr")
    }

    private func toggle() {
        AppHaptics.light()
        if showsSummary {
            withAnimation(.smooth(duration: 0.25)) { showsSummary = false }
            return
        }
        Task {
            let summary = await summaries.summary(id: id, text: text)
            failed = summary == nil
            if summary != nil {
                withAnimation(.smooth(duration: 0.25)) { showsSummary = true }
            } else {
                AppHaptics.error()
            }
        }
    }
}

extension View {
    /// The TL;DR button on a long agent message's bubble (`MessageSummary.isLong`), where the
    /// on-device model is available.
    @ViewBuilder
    func tldr(id: String, text: String, showsSummary: Binding<Bool>) -> some View {
        if MessageSummary.isLong(text), MessageSummaries.shared.available {
            padding(.top, 12)
                .overlay(alignment: .topTrailing) {
                    TLDRButton(id: id, text: text, showsSummary: showsSummary)
                        .offset(x: 10)
                }
        } else {
            self
        }
    }
}
