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
            DictationDiagnosticsSection(whisperInstalled: library.installed != nil)
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
                Task { await WhisperRuntime.shared.unload(.deleted) }
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

/// The last dictation and the Whisper model in memory: where to look when dictation was slow or
/// wrote nothing.
private struct DictationDiagnosticsSection: View {
    let whisperInstalled: Bool
    private let diagnostics = DictationDiagnostics.shared

    var body: some View {
        let take = diagnostics.lastTake
        if take != nil || whisperInstalled {
            Section {
                if let take {
                    LabeledContent("Last Dictation", value: take.date.formatted(.relative(presentation: .named)))
                    LabeledContent("Engine Used", value: Self.engine(take))
                    LabeledContent("First Words", value: take.firstText.map(Self.seconds) ?? String(localized: "None"))
                    if take.whisperPasses > 0, let slowest = take.slowestPass {
                        LabeledContent("Whisper Passes", value: String(localized: "\(take.whisperPasses) · slowest \(Self.seconds(slowest))"))
                    }
                    if let loudest = take.loudestLevel, let background = take.backgroundLevel {
                        // Whisper reads only speech 12 dB above the room: with less it heard none.
                        LabeledContent("Voice · Room", value: "\(Self.decibels(loudest)) · \(Self.decibels(background))")
                    }
                    LabeledContent("Device", value: Self.device(take))
                }
                if whisperInstalled {
                    LabeledContent("Whisper Model", value: Self.model(diagnostics.whisperStatus))
                    if let load = diagnostics.whisperStatus.lastLoadSeconds {
                        LabeledContent("Last Load", value: Self.seconds(load))
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("The last dictation on this device: which engine wrote it, and how long the first words took.")
            }
        }
    }

    private static func engine(_ take: DictationReport) -> String {
        let name = DictationSettingsView.name(take.engine)
        switch take.fallback {
        case nil: return name
        case .whisperNotLoaded: return String(localized: "\(name) · Whisper wasn't loaded")
        case .whisperTooSlow: return String(localized: "\(name) · Whisper was too slow")
        case .whisperFailed: return String(localized: "\(name) · Whisper failed")
        }
    }

    private static func device(_ take: DictationReport) -> String {
        var parts: [String] = []
        switch ProcessInfo.ThermalState(rawValue: take.thermalState) {
        case .fair: parts.append(String(localized: "Warm"))
        case .serious: parts.append(String(localized: "Hot"))
        case .critical: parts.append(String(localized: "Very Hot"))
        default: break
        }
        if take.lowPowerMode { parts.append(String(localized: "Low Power Mode")) }
        return parts.isEmpty ? String(localized: "Normal") : parts.joined(separator: " · ")
    }

    private static func model(_ status: WhisperModelStatus) -> String {
        let since = status.since.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""
        switch status.phase {
        case .loaded: return String(localized: "Loaded") + since
        case .loading: return String(localized: "Loading…") + since
        case .failed: return String(localized: "Failed: \(status.failure ?? "")")
        case .notLoaded:
            switch status.unloaded {
            case .background: return String(localized: "Not loaded · app left the screen") + since
            case .lowMemory: return String(localized: "Not loaded · low memory") + since
            case .deleted, nil: return String(localized: "Not loaded")
            }
        }
    }

    private static func decibels(_ value: Float) -> String {
        String(localized: "\(Int(value.rounded())) dB")
    }

    private static func seconds(_ value: TimeInterval) -> String {
        guard value >= 60 else { return String(localized: "\(value.formatted(.number.precision(.fractionLength(1)))) s") }
        return Duration.seconds(value).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
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
