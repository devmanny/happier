#if os(iOS)
import HappierKit
import SwiftUI

/// Shown when the dictation keyboard opened the app: it's listening, what it hears, and how to go
/// back to the app you were typing in (the system's ◀ in the top-left corner).
struct DictationKeyboardPanel: View {
    @Environment(DictationKeyboardService.self) private var keyboard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: keyboard.dictation.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(keyboard.microphoneOn ? Color.accentColor : .secondary)
                    .symbolEffect(.variableColor.iterative, isActive: keyboard.dictation.isRecording)
                    .frame(height: 56)

                Text(headline)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                ScrollView {
                    Text(keyboard.status.text.isEmpty ? String(localized: "Start talking…") : keyboard.status.text)
                        .font(.body)
                        .foregroundStyle(keyboard.status.text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(16)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))

                if let error = keyboard.status.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Text("Go back to your app with ◀ in the top-left corner. The text appears where you were typing, and the microphone stays on for 5 minutes so you can keep dictating from the keyboard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 0)

                if keyboard.dictation.isRecording {
                    Button {
                        Task { await keyboard.finishTake() }
                    } label: {
                        Label("Stop listening", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                if keyboard.microphoneOn {
                    Button(role: .destructive) {
                        keyboard.turnOff()
                        dismiss()
                    } label: {
                        Text("Turn Off Microphone").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(24)
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
        switch keyboard.status.phase {
        case .off: String(localized: "Microphone off")
        case .ready: String(localized: "Microphone on")
        case .starting: String(localized: "Starting…")
        case .recording: String(localized: "Listening")
        case .finishing: String(localized: "Writing the last words…")
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
                .presentationDetents([.medium, .large])
        }
    }
}
#endif
