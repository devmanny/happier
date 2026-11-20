#if os(iOS)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Happier reading aloud, outside the app: the Dynamic Island (a speaker while it talks, the
/// conversation and controls when expanded) and the Lock Screen.
struct ReadAloudLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReadAloudAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        BlueLogo(size: 20)
                        Speaker(state: state)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.waiting > 0 {
                        Text("+\(state.waiting)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.blue, in: Capsule())
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.snippet.isEmpty ? String(localized: "Listening for new messages…") : state.snippet)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Controls(state: state)
                    }
                }
            } compactLeading: {
                BlueLogo(size: 18)
            } compactTrailing: {
                if state.waiting > 0 {
                    Text("\(state.waiting)").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.blue)
                } else {
                    Speaker(state: state)
                }
            } minimal: {
                BlueLogo(size: 16)
            }
            .keylineTint(.blue)
        }
    }
}

/// Happier's mark in its blue.
private struct BlueLogo: View {
    let size: CGFloat
    var body: some View {
        Image("Logo").renderingMode(.template).resizable().scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.blue)
    }
}

/// A sound wave moving while it reads; a pause sign while paused.
private struct Speaker: View {
    let state: ReadAloudAttributes.ContentState
    var body: some View {
        if state.isPaused {
            Image(systemName: "pause.fill").foregroundStyle(.secondary)
        } else {
            Image(systemName: "waveform")
                .foregroundStyle(.blue)
                .symbolEffect(.variableColor.iterative, isActive: state.isSpeaking)
        }
    }
}

/// Pause/resume, next message and stop, run by the app.
private struct Controls: View {
    let state: ReadAloudAttributes.ContentState
    var body: some View {
        HStack(spacing: 10) {
            Button(intent: ReadAloudTogglePauseIntent()) {
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity)
            }
            .disabled(!state.isSpeaking)
            Button(intent: ReadAloudNextIntent()) {
                Image(systemName: "forward.end.fill").frame(maxWidth: .infinity)
            }
            .disabled(state.waiting == 0)
            Button(intent: ReadAloudStopIntent()) {
                Image(systemName: "xmark").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .tint(.blue)
        .font(.body.weight(.semibold))
    }
}

private struct LockScreenView: View {
    let state: ReadAloudAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BlueLogo(size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(.headline).lineLimit(1)
                    Text(state.autoRead ? "Reading new messages aloud" : "Reading aloud")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Speaker(state: state).font(.title3)
                if state.waiting > 0 {
                    Text("+\(state.waiting)").font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.blue, in: Capsule())
                }
            }
            Text(state.snippet.isEmpty ? String(localized: "Listening for new messages…") : state.snippet)
                .font(.subheadline)
                .lineLimit(2)
            Controls(state: state)
        }
        .padding()
    }
}
#endif
