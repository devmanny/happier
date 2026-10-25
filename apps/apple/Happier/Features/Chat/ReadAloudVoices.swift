import AVFoundation
import HappierKit
import SwiftUI

/// Settings: the voice that reads messages aloud in each of the user's languages, with a sample.
struct ReadAloudVoices: View {
    @State private var voices = MessageSpeaker.installedVoices()
    /// Bumped when a voice is picked, so the rows read the new choice.
    @State private var picks = 0

    /// The user's languages, once each (es-MX and es-US are both Spanish).
    private var languages: [String] {
        var seen = Set<String>()
        return Locale.preferredLanguages.map(SpeechLanguage.languageCode).filter { seen.insert($0).inserted }
    }

    var body: some View {
        Section {
            ForEach(languages, id: \.self) { language in
                row(language)
            }
        } header: {
            Text("Read Aloud")
        } footer: {
            #if os(iOS)
            Text("For voices that sound more natural, download Enhanced or Premium ones in Settings › Accessibility › Spoken Content › Voices. Siri's voices can't be used by apps.")
            #else
            Text("For voices that sound more natural, download Enhanced or Premium ones in System Settings › Accessibility › Spoken Content › System Voice › Manage Voices. Siri's voices can't be used by apps.")
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            voices = MessageSpeaker.installedVoices()
        }
    }

    private func row(_ language: String) -> some View {
        let options = voices
            .filter { SpeechLanguage.languageCode($0.language) == language }
            // Most natural first; the old Eloquence synthesizers last.
            .sorted { a, b in
                (b.quality, a.id.contains(".eloquence.") ? 1 : 0, a.name) < (a.quality, b.id.contains(".eloquence.") ? 1 : 0, b.name)
            }
        let automatic = SpeechLanguage.voice(for: language, region: Locale.current.region?.identifier, among: voices, chosen: nil)
        let selection = Binding<String>(
            get: { _ = picks; return UserDefaults.standard.string(forKey: MessageSpeaker.voiceKey(language)) ?? "" },
            set: { id in
                if id.isEmpty {
                    UserDefaults.standard.removeObject(forKey: MessageSpeaker.voiceKey(language))
                } else {
                    UserDefaults.standard.set(id, forKey: MessageSpeaker.voiceKey(language))
                }
                picks += 1
                MessageSpeaker.shared.preview(MessageSpeaker.voice(language: language), language: language)
            })
        return HStack {
            Picker(Locale.current.localizedString(forLanguageCode: language)?.capitalized ?? language, selection: selection) {
                Text(automatic.map { "Most Natural (\(label($0)))" } ?? String(localized: "System Voice")).tag("")
                ForEach(options) { voice in
                    Text(label(voice)).tag(voice.id)
                }
            }
            Button {
                MessageSpeaker.shared.preview(MessageSpeaker.voice(language: language), language: language)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Play a sample"))
        }
    }

    /// "Paulina · Premium · Mexico".
    private func label(_ voice: SpeechLanguage.Voice) -> String {
        let quality = switch voice.quality {
        case 2: String(localized: "Premium")
        case 1: String(localized: "Enhanced")
        default: String(localized: "Basic")
        }
        let region = voice.language.split(separator: "-").dropFirst().first.flatMap { Locale.current.localizedString(forRegionCode: String($0)) }
        return [voice.name, quality, region].compactMap { $0 }.joined(separator: " · ")
    }
}
