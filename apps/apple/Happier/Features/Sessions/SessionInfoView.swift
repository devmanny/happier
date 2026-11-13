import HappierKit
import SwiftUI

/// Read-only details from the same decrypted session and machine already used by the chat.
struct SessionInfoView: View {
    let sessionId: String
    @Environment(HappierStore.self) private var store
    @State private var copiedIdentifier: String?

    private var session: Session? { store.sessions[sessionId] }
    private var machine: Machine? { store.machines.first { $0.id == session?.machineId } }

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    Form {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(session.title)
                                    .font(.title2.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .accessibilityAddTraits(.isHeader)
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    ViewThatFits(in: .horizontal) {
                                        HStack(spacing: 6) {
                                            Text(providerName(session))
                                            Text("·").accessibilityHidden(true)
                                            status(session, at: store.presenceDate(context.date))
                                        }
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(providerName(session))
                                            status(session, at: store.presenceDate(context.date))
                                        }
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        Section("Session IDs") {
                            identifier("Happier Session ID", value: session.id, copyLabel: "Copy Happier Session ID")
                            if let providerId = session.vendorSessionId {
                                identifier("Provider Session ID", value: providerId, copyLabel: "Copy Provider Session ID")
                            }
                        }
                        let machineName = machine?.name ?? session.host ?? session.machineId
                        if machineName?.isEmpty == false || session.path?.isEmpty == false {
                            Section("Location") {
                                if let name = machineName, !name.isEmpty {
                                    LabeledContent("Machine") {
                                        Text(name).textSelection(.enabled)
                                    }
                                }
                                if let path = session.path, !path.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Directory")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Text(path)
                                            .font(.callout.monospaced())
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        let technical = technicalDetails(session)
                        if !technical.isEmpty || session.createdAt != .distantPast || session.updatedAt != .distantPast {
                            Section {
                                DisclosureGroup("Technical Details") {
                                    if session.createdAt != .distantPast {
                                        LabeledContent("Created") {
                                            Text(session.createdAt, format: .dateTime.year().month().day().hour().minute())
                                        }
                                    }
                                    if session.updatedAt != .distantPast {
                                        LabeledContent("Updated") {
                                            Text(session.updatedAt, format: .dateTime.year().month().day().hour().minute())
                                        }
                                    }
                                    ForEach(technical.indices, id: \.self) { index in
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(technical[index].title).foregroundStyle(.secondary)
                                            Text(technical[index].value)
                                                .font(.callout.monospaced())
                                                .textSelection(.enabled)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                } else {
                    ContentUnavailableView("Session Unavailable", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .navigationTitle("Session Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheetCloseButton()
        }
    }

    private func identifier(_ title: LocalizedStringKey, value: String, copyLabel: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                MessageClipboard.copy(value)
                AppHaptics.success()
                copiedIdentifier = value
            } label: {
                Image(systemName: copiedIdentifier == value ? "checkmark" : "doc.on.doc")
                    .font(.callout)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(copyLabel))
            .accessibilityValue(copiedIdentifier == value ? Text("Copied") : Text(""))
            .help(Text(copyLabel))
        }
        .padding(.vertical, 4)
    }

    private func providerName(_ session: Session) -> String {
        session.agentId.flatMap { Agent.displayNames[$0] }
            ?? session.metadata["flavor"]?.stringValue ?? String(localized: "Agent")
    }

    @ViewBuilder
    private func status(_ session: Session, at date: Date) -> some View {
        if session.isResting {
            // Put to rest by the idle cleaner; the label reads "Resting" once to VoiceOver.
            Label { Text("Resting") } icon: { Image(systemName: "zzz") }
                .labelStyle(.titleAndIcon)
        } else if session.archivedAt != nil {
            Text("Archived")
        } else {
            switch session.status(at: date) {
            case .permissionRequired: Text("Needs your approval")
            case .actionRequired: Text("Waiting for your answer")
            case .working: Text("Working")
            case .failed: Text("Turn failed")
            case .idle: Text("Online")
            case .offline: Text("Stopped")
            }
        }
    }

    private func technicalDetails(_ session: Session) -> [(title: LocalizedStringKey, value: String)] {
        let fields: [(LocalizedStringKey, String?)] = [
            ("CLI Version", session.metadata["version"]?.stringValue),
            ("Operating System", session.metadata["os"]?.stringValue),
            ("Process ID", session.metadata["hostPid"]?.intValue.map(String.init)),
            ("Log Path", session.metadata["sessionLogPath"]?.stringValue),
        ]
        return fields.compactMap { title, value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (title, value)
        }
    }
}
