#if os(iOS)
import HappierKit
import SwiftUI

/// Shown when the dictation keyboard opened the app. The app only opens to turn the microphone on
/// (a keyboard can't), so this says that and how to go back: the system's "◀ App" in the top-left
/// corner, which returns to the exact app you came from. Nothing here takes typing or dictation.
struct DictationKeyboardPanel: View {
    @Environment(DictationKeyboardService.self) private var keyboard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: keyboard.microphoneOn ? "checkmark.circle.fill" : "mic.circle")
                        .font(.system(size: 52, weight: .regular))
                        .foregroundStyle(keyboard.microphoneOn ? Color.green : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(height: 60)

                    Text(headline)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)

                    if let error = keyboard.status.error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Happier opens this one time to turn on the microphone, because a keyboard can't do it by itself. Now go back to the app you were typing in and tap the microphone again to dictate.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    BackHint()

                    Text("The microphone stays on for 5 minutes after your last dictation, so you can keep dictating without coming back here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if keyboard.microphoneOn {
                        Button(role: .destructive) {
                            keyboard.turnOff()
                            dismiss()
                        } label: {
                            Text("Turn Off Microphone")
                        }
                        .buttonStyle(.borderless)
                        .font(.footnote)
                    }
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Dictation Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var headline: String {
        if keyboard.status.error != nil { return String(localized: "The microphone couldn't turn on") }
        return keyboard.microphoneOn
            ? String(localized: "The keyboard can listen now")
            : String(localized: "Turning on the microphone…")
    }
}

/// A sketch of the screen's top-left corner, pointing at the system's back button. It names no app:
/// the button shows whichever app you came from.
private struct BackHint: View {
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                UnevenRoundedRectangle(topLeadingRadius: 34, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.5), lineWidth: 2)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 34, style: .continuous)
                            .fill(.quaternary.opacity(0.35))
                    )

                HStack(spacing: 2) {
                    Image(systemName: "arrowtriangle.left.fill").font(.system(size: 11))
                    Text("App name").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    Capsule()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .scaleEffect(pulsing ? 1.12 : 0.96)
                        .opacity(pulsing ? 0.15 : 0.9)
                }
                .padding(.top, 16)
                .padding(.leading, 22)

                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.primary.opacity(0.75))
                    .offset(x: 92, y: 44)
            }
            .frame(width: 240, height: 110)
            .clipped()
            .accessibilityHidden(true)

            Text("Tap ◀ in the top-left corner")
                .font(.callout.weight(.medium))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulsing = true }
        }
    }
}
#endif

#if os(iOS)
/// Presents the panel while the app was opened from the dictation keyboard.
struct DictationKeyboardSheet: ViewModifier {
    @Environment(DictationKeyboardService.self) private var keyboard

    func body(content: Content) -> some View {
        @Bindable var keyboard = keyboard
        content.sheet(isPresented: $keyboard.showsPanel) {
            DictationKeyboardPanel()
                .environment(keyboard)
                .presentationDetents([.large])
        }
    }
}
#endif
