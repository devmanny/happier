import HappierKit
import SwiftUI

/// One toolbar control: session context outside, the provider's weekly limit inside.
struct SessionUsageButton: View {
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
        Button { showDetails = true } label: {
            ZStack {
                ring(fraction: contextFraction, tint: .primary, diameter: 20)
                ring(fraction: weekly.map { $0.usedPercent / 100 },
                     tint: weekly.map(quotaTint) ?? .secondary, diameter: 11)
            }
            .frame(width: 24, height: 24)
        }
        .accessibilityLabel(Text("Usage statistics"))
        .accessibilityValue(accessibilityValue)
        .help(Text("Session context and weekly usage"))
        .popover(isPresented: $showDetails) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
