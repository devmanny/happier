import HappierKit
import SwiftUI

/// Settings › Oído: start or pause listening, where the audio goes, and how it's doing.
struct OidoSettingsView: View {
    @Environment(HappierStore.self) private var store
    @Environment(OidoController.self) private var oido
    @State private var deviceName = ""
    #if os(macOS)
    @State private var opensAtLogin = false
    #endif

    var body: some View {
        @Bindable var oido = oido
        Form {
            Section {
                Toggle(isOn: Binding(get: { oido.isListening }, set: { on in
                    if on { Task { await oido.start() } } else { oido.pause() }
                })) {
                    Label("Listen", systemImage: "ear")
                }
                .disabled(oido.machineId == nil && !oido.isListening)
                OidoStatusRows()
            } footer: {
                Text("Keeps only the speech, sends it to your Mac in chunks and transcribes it there. Nothing is stored on the relay.")
            }

            Section {
                Picker("Transcribing Mac", selection: $oido.machineId) {
                    Text("Choose…").tag(String?.none)
                    ForEach(store.machines) { machine in
                        Text(machine.name).tag(Optional(machine.id))
                    }
                }
                TextField("Inbox Folder", text: $oido.remoteDirectory)
                    .autocorrectionDisabled()
                TextField("This Device's Name", text: $deviceName)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(applyDeviceName)
            } header: {
                Text("Destination")
            } footer: {
                Text("The folder is on that Mac, relative to its home folder. Turn on [inbox] in the oido config there (or run oido inbox) to receive what arrives. The device name labels the transcripts and applies the next time listening starts.")
            }

            #if os(macOS)
            Section {
                Toggle("Open Happier at Login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, value in
                        oido.opensAtLogin = value
                        opensAtLogin = oido.opensAtLogin
                    }
                Toggle("Show in Menu Bar", isOn: $oido.showInMenuBar)
            } footer: {
                Text("Happier keeps listening with its windows closed. While it listens, the Mac doesn't go to sleep on its own.")
            }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Oído")
        .task {
            deviceName = oido.deviceId
            #if os(macOS)
            opensAtLogin = oido.opensAtLogin
            #endif
            await store.refreshMachines()
        }
        .onDisappear(perform: applyDeviceName)
    }

    private func applyDeviceName() {
        if let id = Oido.deviceId(from: deviceName) { oido.deviceId = id }
        deviceName = oido.deviceId
    }
}

/// Listening state, queue and last upload; shared by Settings and the menu bar.
struct OidoStatusRows: View {
    @Environment(OidoController.self) private var oido

    var body: some View {
        LabeledContent("Status") {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(stateText)
            }
        }
        LabeledContent("Waiting to Send", value: "\(oido.upload.pending)")
        if let last = oido.upload.lastUploadAt {
            LabeledContent("Last Sent") { Text(last, format: .relative(presentation: .named)) }
        }
        if let error = oido.upload.lastError, oido.upload.pending > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Retry Now") { oido.retryUploads() }
            }
        }
    }

    private var stateText: String { oido.stateDescription }
    private var color: Color { oido.stateColor }
}

extension OidoController {
    /// The state in words, the same in Settings, the menu bar and the iPhone's button.
    var stateDescription: String {
        switch state {
        case .paused: String(localized: "Paused")
        case .starting: String(localized: "Starting…")
        case .listening: hearingSpeech ? String(localized: "Listening · hearing speech") : String(localized: "Listening")
        case .interrupted: String(localized: "Paused while a call or another app uses the microphone; resumes by itself")
        case .failed(let message): message
        }
    }

    var stateColor: Color {
        switch state {
        case .listening: hearingSpeech ? .green : .blue
        case .starting: .yellow
        case .interrupted: .orange
        case .paused: .secondary
        case .failed: .red
        }
    }
}

#if os(macOS)
/// The menu bar item: the same toggle and status with every window closed.
struct OidoMenuBarContent: View {
    @Environment(OidoController.self) private var oido
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(oido.isListening ? "Pause Listening" : "Start Listening") { oido.toggle() }
            .disabled(oido.machineId == nil && !oido.isListening)
        Divider()
        Text(summary)
        if let error = oido.upload.lastError, oido.upload.pending > 0 { Text(error) }
        Divider()
        Button("Oído Settings…") {
            NSApp.activate()
            openSettings()
        }
    }

    private var summary: String {
        var parts = [oido.stateDescription]
        if oido.upload.pending > 0 { parts.append(String(localized: "\(oido.upload.pending) waiting to send")) }
        return parts.joined(separator: " · ")
    }
}

struct OidoMenuBarLabel: View {
    @Environment(OidoController.self) private var oido

    var body: some View {
        Image(systemName: oido.isListening ? "ear.fill" : "ear")
            .accessibilityLabel(oido.isListening ? Text("Oído is listening") : Text("Oído is paused"))
    }
}
#endif

#if os(iOS)
/// Oído beside Settings at the foot of the sessions list (the iPhone has no menu bar): a tap
/// turns it on or off, touching and holding shows how it's doing and its settings. The ear
/// says the state: filled while on, with a warning while the microphone is taken or it failed.
struct OidoQuickButton: View {
    @Environment(OidoController.self) private var oido
    @State private var showSettings = false

    var body: some View {
        Menu {
            Section {
                Text(oido.stateDescription)
                if oido.machineId == nil {
                    Text("Choose the Mac that transcribes in Oído Settings.")
                }
                if oido.upload.pending > 0 {
                    Text("\(oido.upload.pending) waiting to send")
                }
                if let error = oido.upload.lastError, oido.upload.pending > 0 {
                    Text(error)
                }
            }
            Button(oido.isListening ? "Pause Listening" : "Start Listening",
                   systemImage: oido.isListening ? "pause.fill" : "ear") { toggle() }
            Button("Oído Settings…", systemImage: "gearshape") { showSettings = true }
        } label: {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: oido.state == .starting || oido.state == .listening && oido.hearingSpeech)
        } primaryAction: {
            toggle()
        }
        .buttonStyle(.glass)
        .glassHover()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel(Text("Oído"))
        .accessibilityValue(Text(oido.stateDescription))
        .accessibilityHint(Text("Turns listening on or off. Touch and hold for more."))
        .accessibilityIdentifier("oido-quick-button")
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                OidoSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
    }

    private var symbol: String {
        switch oido.state {
        case .listening, .starting: "ear.fill"
        case .interrupted, .failed: "ear.trianglebadge.exclamationmark"
        case .paused: "ear"
        }
    }

    private var tint: Color {
        oido.state == .paused ? .primary : oido.stateColor
    }

    /// Without a Mac to send to, starting would only fill the queue: the settings open instead.
    private func toggle() {
        AppHaptics.light()
        if !oido.isListening, oido.machineId == nil {
            showSettings = true
        } else {
            oido.toggle()
        }
    }
}
#endif
