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

    private var stateText: String {
        switch oido.state {
        case .paused: String(localized: "Paused")
        case .starting: String(localized: "Starting…")
        case .listening: oido.hearingSpeech ? String(localized: "Listening · hearing speech") : String(localized: "Listening")
        case .failed(let message): message
        }
    }

    private var color: Color {
        switch oido.state {
        case .listening: oido.hearingSpeech ? .green : .blue
        case .starting: .yellow
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
        var parts: [String] = []
        switch oido.state {
        case .paused: parts.append(String(localized: "Paused"))
        case .starting: parts.append(String(localized: "Starting…"))
        case .listening: parts.append(String(localized: "Listening"))
        case .failed(let message): parts.append(message)
        }
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
