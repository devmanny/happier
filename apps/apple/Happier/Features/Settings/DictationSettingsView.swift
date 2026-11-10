import HappierKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Settings › Dictation: which engine dictates on this device, and the Whisper model it downloads
/// (once, over the network) to dictate on the device itself.
struct DictationSettingsView: View {
    @State private var engine: DictationEngine?
    @State private var language: String?
    @State private var deleting: WhisperModel?
    private let library = WhisperModels.library

    var body: some View {
        Form {
            Section {
                LabeledContent("Engine", value: engine.map(Self.name) ?? "…")
                LabeledContent("Language", value: languageName)
            } footer: {
                Text("Whisper runs on this device: your voice never leaves it. Until a Whisper model is downloaded, dictation uses Apple's speech recognition.")
            }
            Section {
                ForEach(WhisperModel.allCases) { model in
                    WhisperModelRow(model: model, library: library, deleting: $deleting)
                }
            } header: {
                Text("Whisper Model")
            } footer: {
                Text("Downloaded once and kept on this device. Keep Happier open until it finishes.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dictation")
        .task(id: library.installed) {
            language = await Dictation.dictationLanguage()
            engine = await DictationRecognizers.engine(language: language)
        }
        .confirmationDialog("Delete the Whisper model?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { model in
            Button("Delete \(model.title)", role: .destructive) {
                AppHaptics.warning()
                library.delete(model)
                Task { await WhisperRuntime.shared.unload() }
            }
        } message: { _ in
            Text("Dictation uses Apple's speech recognition until you download a model again.")
        }
    }

    private var languageName: String {
        guard let language else { return "…" }
        return Locale.current.localizedString(forIdentifier: language) ?? language
    }

    static func name(_ engine: DictationEngine) -> String {
        switch engine {
        case .whisper(let model): String(localized: "Whisper \(model.title)")
        case .speechTranscriber: String(localized: "Apple Speech")
        case .speechRecognizer: String(localized: "Apple Speech (Classic)")
        }
    }
}

private struct WhisperModelRow: View {
    let model: WhisperModel
    let library: WhisperModelLibrary
    @Binding var deleting: WhisperModel?

    private var runsHere: Bool { model.runs(onDeviceSupporting: WhisperModels.deviceSupports) }

    var body: some View {
        let state = library.state(of: model)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                    Text(detail(state))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                action(state)
            }
            switch state {
            case .downloading(let fraction):
                ProgressView(value: fraction)
            case .preparing:
                ProgressView()
                    .progressViewStyle(.linear)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            case .absent, .installed:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(_ state: WhisperModelLibrary.State) -> String {
        let size = Self.megabytes(model.downloadBytes)
        switch state {
        case .downloading(let fraction):
            return String(localized: "Downloading… \(Self.megabytes(Int64(Double(model.downloadBytes) * fraction))) of \(size)")
        case .preparing:
            return String(localized: "Preparing for this device. The first time takes a few minutes.")
        case .installed(let bytes):
            return String(localized: "In use · \(Self.megabytes(bytes)) on this device")
        case .absent, .failed:
            return runsHere ? "\(model.summary) · \(size)" : String(localized: "Not available on this device")
        }
    }

    @ViewBuilder private func action(_ state: WhisperModelLibrary.State) -> some View {
        switch state {
        case .absent, .failed:
            if runsHere {
                Button(state == .absent ? "Download" : "Try Again") {
                    AppHaptics.light()
                    Task { await download() }
                }
                .buttonStyle(.glass)
                .disabled(library.isBusy)
            }
        case .downloading, .preparing:
            Button("Cancel", role: .cancel) {
                library.cancel()
            }
            .buttonStyle(.glass)
        case .installed:
            Button("Delete", role: .destructive) {
                deleting = model
            }
            .buttonStyle(.glass)
            .tint(.red)
        }
    }

    /// The screen stays on meanwhile: a locked phone suspends the app and the download stops.
    private func download() async {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        await library.download(model)
        if library.installed == model { AppHaptics.success() }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, allowedUnits: [.mb, .gb]))
    }
}

extension WhisperModel {
    var title: String {
        switch self {
        case .largeV3Turbo: String(localized: "Large v3 Turbo")
        }
    }

    var summary: String {
        switch self {
        case .largeV3Turbo: String(localized: "Most accurate")
        }
    }
}
