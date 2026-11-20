import HappierKit
import SwiftUI
import UIKit

struct KeyboardView: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 6) {
            caption
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
                .padding(.horizontal, 12)

            // The mic in the middle; delete over return on the right, centered on the mic; space
            // under the mic.
            Grid(horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    VStack(spacing: 8) {
                        if model.needsGlobe, let controller = model.globeTarget {
                            GlobeKey(controller: controller).frame(height: 44)
                        }
                        if model.microphoneOn, !model.listening {
                            Key(systemImage: "mic.slash", accessibility: "Turn off microphone", action: model.turnMicrophoneOff)
                                .frame(height: 44)
                        }
                    }
                    .frame(width: Self.sideWidth)

                    if model.hasFullAccess {
                        MicButton(listening: model.listening, waiting: model.waiting, action: model.micTapped)
                    } else {
                        Text("Turn on Allow Full Access in Settings › General › Keyboard › Keyboards › Happier, so the keyboard can type what the app hears.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 240)
                    }

                    VStack(spacing: 8) {
                        RepeatingKey(systemImage: "delete.left", accessibility: "Delete", action: model.deleteBackward)
                            .frame(height: 44)
                        Key(title: model.returnTitle, action: model.newline)
                            .frame(height: 44)
                    }
                    .frame(width: Self.sideWidth)
                }
                GridRow {
                    Color.clear.frame(width: Self.sideWidth, height: 1)
                    SpaceKey(model: model)
                        .frame(width: 190, height: 44)
                    Color.clear.frame(width: Self.sideWidth, height: 1)
                }
            }
            .frame(maxWidth: .infinity)
            .opacity(model.trackpad ? 0.25 : 1)
            .animation(.easeOut(duration: 0.15), value: model.trackpad)
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private static let sideWidth: CGFloat = 84

    /// Only what needs saying: why the microphone can't start, or what the first tap does. The
    /// words being heard go straight into the text field (shown here too, they piled up and
    /// didn't follow deletes).
    @ViewBuilder private var caption: some View {
        let status = model.status
        if let error = status?.error, !(status?.isListening ?? false) {
            Text(error).font(.footnote).foregroundStyle(.red).lineLimit(2)
        } else if model.hasFullAccess, !model.microphoneOn, !model.listening {
            Text("The first time, Happier opens to turn on the microphone. Come back with ◀ and it starts listening.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineLimit(2)
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

/// Space: a tap types a space; held, the keyboard becomes a trackpad and dragging moves the cursor,
/// sideways a character at a time and up or down a line at a time.
private struct SpaceKey: View {
    let model: KeyboardModel
    @State private var hold: Task<Void, Never>?
    @State private var touching = false
    /// Where the finger is, and where the cursor last moved from (in trackpad mode).
    @State private var finger: CGPoint = .zero
    @State private var anchor: CGPoint?

    private static let holdDelay: Duration = .milliseconds(350)
    private static let characterStep: CGFloat = 9
    private static let lineStep: CGFloat = 22

    var body: some View {
        KeyFace { Text("space").font(.system(size: 16)) }
            .opacity(model.trackpad ? 0 : 1)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    finger = value.location
                    if !touching {
                        touching = true
                        hold = Task { @MainActor in
                            try? await Task.sleep(for: Self.holdDelay)
                            guard !Task.isCancelled else { return }
                            anchor = finger
                            model.trackpadBegan()
                        }
                    }
                    if model.trackpad { follow() }
                }
                .onEnded { _ in
                    hold?.cancel()
                    hold = nil
                    if model.trackpad { model.trackpadEnded() } else { model.space() }
                    touching = false
                    anchor = nil
                })
            .accessibilityLabel(Text("space"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.space() }
    }

    private func follow() {
        guard var anchor else { return }
        let characters = Int((finger.x - anchor.x) / Self.characterStep)
        if characters != 0 {
            model.moveCursor(by: characters)
            anchor.x += CGFloat(characters) * Self.characterStep
        }
        // One line per event: the text around the cursor only catches up after each move.
        let lines = (finger.y - anchor.y) / Self.lineStep
        if lines <= -1 {
            model.moveLine(.up)
            anchor.y -= Self.lineStep
        } else if lines >= 1 {
            model.moveLine(.down)
            anchor.y += Self.lineStep
        }
        self.anchor = anchor
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
