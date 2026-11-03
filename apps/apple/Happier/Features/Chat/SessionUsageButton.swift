import HappierKit
import SwiftUI

/// One toolbar control: session context outside, the provider's weekly limit inside.
struct SessionUsageButton: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store
    let context: ContextUsage?
    let window: Int?
    let usage: ProviderUsage?
    let modelId: String?
    let agentName: String?
    @State private var showDetails = false

    private var weekly: ProviderUsage.Meter? { usage?.weeklyLimit(modelId: modelId) }
    private var contextFraction: Double? {
        guard let context, let window, window > 0 else { return nil }
        return min(max(Double(context.usedTokens) / Double(window), 0), 1)
    }
    private func quotaTint(_ meter: ProviderUsage.Meter) -> Color {
        meter.remainingPercent <= 10 ? .red : meter.remainingPercent <= 25 ? .orange : .userBubble
    }

    var body: some View {
        Button {
            AppHaptics.light()
            showDetails = true
        } label: {
            ZStack {
                ring(fraction: contextFraction, tint: .primary, diameter: 20)
                ring(fraction: weekly.map { $0.usedPercent / 100 },
                     tint: weekly.map(quotaTint) ?? .secondary, diameter: 11)
            }
            .frame(width: 24, height: 24)
        }
        .accessibilityLabel(Text("Usage statistics"))
        .accessibilityValue(accessibilityValue)
        .help(Text("Recorded tokens, session context and account usage"))
        .popover(isPresented: $showDetails) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SessionTokenDetails(sessionId: sessionId)
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Session Context", systemImage: "circle")
                            .font(.headline)
                        if let context, let window, let fraction = contextFraction {
                            Text("\(Int((fraction * 100).rounded()))% used · \(context.usedTokens.formatted(.number.notation(.compactName))) of \(window.formatted(.number.notation(.compactName))) tokens")
                                .monospacedDigit()
                            ProgressView(value: fraction).tint(.primary)
                            Text("Outer ring · The agent compacts its context automatically when it fills up.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Context usage is not available yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Weekly Usage", systemImage: "circle.inset.filled")
                            .font(.headline)
                        if let weekly {
                            Text(weekly.label).font(.subheadline.weight(.medium))
                            quotaDetails(weekly)
                        } else {
                            Text("Weekly usage is not available yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text("Inner ring · \(agentName ?? String(localized: "Provider"))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let plan = usage?.planLabel {
                            Text("Plan: \(plan.capitalized)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let usage {
                        let otherMeters = usage.meters.filter { $0.id != weekly?.id }
                        if !otherMeters.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Other Limits").font(.headline)
                                ForEach(otherMeters) { meter in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(meter.label).font(.subheadline.weight(.medium))
                                        quotaDetails(meter)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(width: 310, alignment: .leading)
            }
            .frame(maxHeight: 480)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func ring(fraction: Double?, tint: Color, diameter: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.18),
                            style: StrokeStyle(lineWidth: 2.75, dash: fraction == nil ? [1, 3] : []))
            if let fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.75, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth, value: fraction)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private func quotaDetails(_ meter: ProviderUsage.Meter) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(Int(meter.usedPercent.rounded()))% used")
                .monospacedDigit()
            ProgressView(value: meter.usedPercent, total: 100).tint(quotaTint(meter))
            if let reset = meter.resetsAt {
                Text("Resets \(reset, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilityValue: Text {
        let context = contextFraction.map { String(localized: "Session context \(Int(($0 * 100).rounded()))% used") }
        let weekly = weekly.map { String(localized: "\($0.label): \(Int($0.usedPercent.rounded()))% used") }
        return Text([context, weekly].compactMap { $0 }.joined(separator: ", "))
    }
}


/// Shared by the sidebar and the chat details. The cache never reads transcript history.
struct SessionTokenIndicator: View {
    let sessionId: String
    let parents: [String: String]
    @Environment(HappierStore.self) private var store

    var body: some View {
        let summary = store.tokenSummary(sessionId, parents: parents)
        Text(label(summary))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(Text("Recorded tokens; tree totals include known descendants. Open usage statistics for details."))
            .task(id: SessionTokenSummary.memberIds(sessionId, parents: parents)) {
                await store.loadSessionTokenUsage(sessionId)
            }
    }

    private func label(_ summary: SessionTokenSummary) -> String {
        let own = summary.own.map { $0.formatted(.number.notation(.compactName)) } ?? "—"
        guard summary.descendantCount > 0 else { return String(localized: "\(own) tokens") }
        let total = summary.total.map { $0.formatted(.number.notation(.compactName)) } ?? "—"
        let partial = summary.missingCount > 0 ? "+" : ""
        return String(localized: "\(own) own · \(total)\(partial) tree tokens")
    }
}

private struct SessionTokenDetails: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store

    var body: some View {
        let summary = store.tokenSummary(sessionId)
        VStack(alignment: .leading, spacing: 6) {
            Label("Recorded Tokens", systemImage: "number.circle").font(.headline)
            LabeledContent("This session", value: count(summary.own))
            if summary.descendantCount > 0 {
                LabeledContent("Descendants (\(summary.descendantCount))", value: count(summary.descendants))
                LabeledContent("Tree total", value: count(summary.total))
            }
            if summary.missingCount > 0 {
                Text("Reports unavailable for \(summary.missingCount) sessions. Totals are partial.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("Input, output and cached tokens reported by agents. Older or unsupported agents may omit usage. Includes known descendants only; these counts do not measure context size or a share of your provider quota.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Refresh token reports", systemImage: "arrow.clockwise") {
                Task { await store.loadSessionTokenUsage(sessionId, refresh: true) }
            }
            .font(.footnote)
        }
        .monospacedDigit()
        .task(id: SessionTokenSummary.memberIds(sessionId, parents: store.sessionUsageParents)) {
            await store.loadSessionTokenUsage(sessionId)
        }
    }

    private func count(_ value: Int?) -> String {
        value.map { $0.formatted() } ?? String(localized: "Unavailable")
    }
}
