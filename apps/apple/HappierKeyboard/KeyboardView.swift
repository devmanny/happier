import HappierKit
import SwiftUI
import UIKit

struct KeyboardView: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 10) {
            caption
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .center)
                .padding(.horizontal, 12)

            if model.hasFullAccess {
                MicButton(listening: model.listening, waiting: model.waiting, action: model.micTapped)
            } else {
                Text("Turn on Allow Full Access in Settings › General › Keyboard › Keyboards › Happier, so the keyboard can type what the app hears.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .frame(maxHeight: .infinity)
            }

            HStack(spacing: 6) {
                GlobeKey(controller: model.globeTarget)
                    .frame(width: 44)
                if model.microphoneOn, !model.listening {
                    Key(systemImage: "mic.slash", accessibility: "Turn off microphone", action: model.turnMicrophoneOff)
                        .frame(width: 44)
                }
                Key(title: String(localized: "space"), action: model.space)
                RepeatingKey(systemImage: "delete.left", accessibility: "Delete", action: model.deleteBackward)
                    .frame(width: 56)
                Key(title: model.returnTitle, action: model.newline)
                    .frame(width: 84)
            }
            .frame(height: 44)
            .padding(.horizontal, 4)
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder private var caption: some View {
        let status = model.status
        if let error = status?.error, !(status?.isListening ?? false) {
            Text(error).font(.footnote).foregroundStyle(.red).lineLimit(2)
        } else if let status, status.isListening {
            Text(status.text.isEmpty ? String(localized: "Listening…") : status.text)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.head)
                .foregroundStyle(status.text.isEmpty ? .secondary : .primary)
        } else if model.microphoneOn {
            Text("Tap to talk").font(.footnote).foregroundStyle(.secondary)
        } else {
            Text("Tap to talk: Happier opens to turn on the microphone, then go back with ◀")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MicButton: View {
    let listening: Bool
    let waiting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(listening ? Color.red : Color.accentColor)
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                if waiting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: listening)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listening ? Text("Stop dictating") : Text("Dictate"))
        .frame(maxHeight: .infinity)
    }
}

private struct Key: View {
    var title: String?
    var systemImage: String?
    var accessibility: LocalizedStringKey?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            KeyFace {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 18))
                } else if let title {
                    Text(title).font(.system(size: 16))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility.map { Text($0) } ?? Text(title ?? ""))
    }
}

/// Delete: once on tap, then repeating while held.
private struct RepeatingKey: View {
    let systemImage: String
    let accessibility: LocalizedStringKey
    let action: () -> Void
    @State private var repeating: Task<Void, Never>?

    var body: some View {
        KeyFace { Image(systemName: systemImage).font(.system(size: 18)) }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard repeating == nil else { return }
                    action()
                    repeating = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        while !Task.isCancelled {
                            action()
                            try? await Task.sleep(for: .milliseconds(90))
                        }
                    }
                }
                .onEnded { _ in
                    repeating?.cancel()
                    repeating = nil
                })
            .accessibilityLabel(Text(accessibility))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

private struct KeyFace<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground).opacity(0.9), in: .rect(cornerRadius: 8))
            .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
            .contentShape(.rect)
    }
}

/// The globe: a tap goes to the next keyboard, a hold lists them (the system's own handling, which
/// needs a UIKit control).
private struct GlobeKey: UIViewRepresentable {
    let controller: UIInputViewController

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))
        configuration.baseForegroundColor = .label
        configuration.background.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        configuration.background.cornerRadius = 8
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = String(localized: "Next keyboard")
        button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
