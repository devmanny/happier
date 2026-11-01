import AVFoundation
import HappierKit
import SwiftUI

/// Settings: the voice that reads messages aloud in each of the user's languages, with a sample.
struct ReadAloudVoices: View {
    @State private var voices = MessageSpeaker.installedVoices()
    @AppStorage(MessageSpeaker.languagesKey) private var languageSelection = ""
    /// Bumped when a voice is picked, so the rows read the new choice.
    @State private var picks = 0

    private var languages: [String] {
        SpeechLanguage.readingLanguages(preferred: Locale.preferredLanguages,
            chosen: languageSelection.split(separator: ",").map(String.init))
    }

    var body: some View {
        Section {
            NavigationLink {
                ReadingLanguagesView(selection: $languageSelection, voices: voices)
            } label: {
                LabeledContent("Languages", value: languages.map(readingLanguageName).joined(separator: ", "))
            }
            ForEach(languages, id: \.self) { language in
                row(language)
            }
        } header: {
            Text("Read Aloud")
        } footer: {
            #if os(iOS)
            Text("Reads only in your selected languages. Choose a voice or play a sample. More voices can be downloaded in Settings › Accessibility › Read & Speak › Voices; availability varies by device.")
            #else
            Text("Reads only in your selected languages. Choose a voice or play a sample. More voices can be downloaded in System Settings › Accessibility › Read & Speak › System Voice; availability varies by device.")
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

/// Reading choices belong to Happier and leave the device's language and Siri settings alone.
private struct ReadingLanguagesView: View {
    @Binding var selection: String
    let voices: [SpeechLanguage.Voice]

    private var selected: [String] {
        SpeechLanguage.readingLanguages(preferred: Locale.preferredLanguages,
            chosen: selection.split(separator: ",").map(String.init))
    }

    private var available: [String] {
        Set(voices.map { SpeechLanguage.languageCode($0.language) } + selected)
            .sorted { readingLanguageName($0).localizedStandardCompare(readingLanguageName($1)) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                Picker("Default Language", selection: Binding(
                    get: { selected[0] },
                    set: { first in selection = ([first] + selected.filter { $0 != first }).joined(separator: ",") }
                )) {
                    ForEach(selected, id: \.self) { language in
                        Text(readingLanguageName(language)).tag(language)
                    }
                }
            } footer: {
                Text("Used when the text has no detectable language. Otherwise, Happier detects the language from the ones enabled below. Applies to individual messages and automatic reading on this device.")
            }
            Section("Reading Languages") {
                ForEach(available, id: \.self) { language in
                    Toggle(readingLanguageName(language), isOn: Binding(
                        get: { selected.contains(language) },
                        set: { enabled in
                            let next = enabled ? selected + [language] : selected.filter { $0 != language }
                            if !next.isEmpty { selection = next.joined(separator: ",") }
                        }
                    ))
                    .disabled(selected.count == 1 && selected.contains(language))
                }
            }
            Section {
                Button("Use Device Languages") { selection = "" }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Reading Languages")
    }
}

private func readingLanguageName(_ language: String) -> String {
    Locale.current.localizedString(forLanguageCode: language)?.capitalized ?? language
}
