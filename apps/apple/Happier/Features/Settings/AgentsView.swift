import HappierKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Agents: the user's agents (name, description, engine and fixed account), synced
/// through the account's encrypted store to every device.
struct AgentsView: View {
    @Environment(HappierStore.self) private var store
    @State private var editing: AgentProfile?

    var body: some View {
        Form {
            if let error = store.agentProfilesError, store.agentProfiles.isEmpty {
                Text(error).foregroundStyle(.secondary)
            } else if store.agentProfiles.isEmpty {
                ContentUnavailableView("No Agents Yet", systemImage: "person.crop.circle.badge.plus",
                                       description: Text("An agent is a name, a description, an engine and an account. Start a session as one from New Session."))
            } else {
                Section {
                    ForEach(store.agentProfiles) { profile in
                        Button {
                            AppHaptics.light()
                            editing = profile
                        } label: {
                            AgentProfileRow(profile: profile)
                        }
                        .buttonStyle(.pressable)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await store.deleteAgentProfile(id: profile.id) }
                            }
                        }
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await store.deleteAgentProfile(id: profile.id) }
                            }
                        }
                    }
                } footer: {
                    if store.agentProfilesComplete {
                        Text("Shared with Happier on your other devices.")
                    } else {
                        Text("Only the first \(KVListing.maxRows) stored records could be read, so some agents may be missing here.")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Agent", systemImage: "plus") {
                    AppHaptics.light()
                    editing = AgentProfile(name: "", emoji: "🤖", providerId: "claude", account: .init(label: ""))
                }
                .disabled(store.agentProfilesError != nil && store.agentProfiles.isEmpty)
            }
        }
        .refreshable { await store.refreshAgentProfiles() }
        .task { await store.refreshAgentProfiles() }
        .sheet(item: $editing) { profile in
            NavigationStack {
                AgentEditor(profile: profile, isNew: !store.agentProfiles.contains { $0.id == profile.id })
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 620)
            #endif
        }
    }
}

/// "🤖 Julián", its engine, and the account it's tied to.
struct AgentProfileRow: View {
    let profile: AgentProfile
    var selected = false
    @Environment(HappierStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Text(profile.emoji ?? "🤖")
                .font(.title2)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).foregroundStyle(.primary)
                Text(AgentProfileText.engine(profile, sessions: Array(store.sessions.values)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(AgentProfileText.account(profile))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.userBubble).fontWeight(.semibold) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

@MainActor
enum AgentProfileText {
    /// "Claude Code · Opus 5.5 · Medium".
    static func engine(_ profile: AgentProfile, sessions: [Session]) -> String {
        var parts = [Agent.displayNames[profile.providerId] ?? profile.providerId]
        parts.append(contentsOf: modelAndEffort(profile, sessions: sessions))
        return parts.joined(separator: " · ")
    }

    /// "Opus 5.5 · Medium", without the provider.
    static func modelAndEffort(_ profile: AgentProfile, sessions: [Session]) -> [String] {
        var parts: [String] = []
        if let modelId = profile.modelId, modelId != "default" {
            let models = SessionControls.newSessionModels(agentId: profile.providerId, sessions: sessions)
            parts.append(models.first { $0.id == modelId }?.name ?? modelId)
        }
        if let effort = profile.effort { parts.append(EffortSlider.name(effort)) }
        return parts
    }

    static func account(_ profile: AgentProfile) -> String {
        let label = profile.account.label.isEmpty ? nil : profile.account.label
        if profile.providerId == "claude", let dir = profile.claudeConfigDir {
            return String(localized: "Account: \(label ?? dir)")
        }
        return label.map { String(localized: "Account: \($0)") } ?? String(localized: "Account: this machine's login")
    }
}

/// Create or edit one agent. Nothing is saved until Save.
private struct AgentEditor: View {
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var profile: AgentProfile
    let isNew: Bool
    @State private var saving = false

    private var models: [ModelChoice] {
        SessionControls.newSessionModels(agentId: profile.providerId, sessions: Array(store.sessions.values))
    }

    private var effortLevels: [String] {
        guard let modelId = profile.modelId else { return [] }
        return models.first { $0.id == modelId }?.effortLevels ?? []
    }

    /// Agents in use first, then the rest of the catalog.
    private var providers: [String] {
        var counts: [String: Int] = [:]
        for session in store.sessions.values { if let id = session.agentId { counts[id, default: 0] += 1 } }
        return Agent.ids.filter { $0 != "customAcp" }.enumerated().sorted { a, b in
            let used = (counts[a.element] ?? 0, counts[b.element] ?? 0)
            return used.0 != used.1 ? used.0 > used.1 : a.offset < b.offset
        }.map(\.element)
    }

    private var canSave: Bool { !saving && !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Form {
            Section("Name and Emoji") {
                HStack {
                    TextField("Emoji", text: optional(\.emoji))
                        .frame(width: 44)
                        .multilineTextAlignment(.center)
                    TextField("Name", text: $profile.name)
                        .accessibilityIdentifier("agent-name")
                }
            }
            Section {
                TextField("Who it is and how it works", text: optional(\.description), axis: .vertical)
                    .lineLimit(4...12)
            } header: {
                Text("Description")
            } footer: {
                Text("The agent receives this at the start of every session, with its name.")
            }
            Section("Engine") {
                Picker("Agent", selection: Binding(get: { profile.providerId }, set: { provider in
                    profile.providerId = provider
                    profile.modelId = nil
                    profile.effort = nil
                })) {
                    ForEach(providers, id: \.self) { Text(Agent.displayNames[$0] ?? $0).tag($0) }
                }
                Picker("Model", selection: Binding(get: { profile.modelId ?? "default" }, set: { model in
                    profile.modelId = model == "default" ? nil : model
                    if let effort = profile.effort, !effortLevels.contains(effort) { profile.effort = nil }
                })) {
                    Text("Use CLI Settings").tag("default")
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
                if !effortLevels.isEmpty {
                    Picker("Effort", selection: Binding(get: { profile.effort ?? "" }, set: { profile.effort = $0.isEmpty ? nil : $0 })) {
                        Text("Model Default").tag("")
                        ForEach(effortLevels, id: \.self) { Text(EffortSlider.name($0)).tag($0) }
                    }
                }
            }
            if !isNew {
                Section {
                    NavigationLink {
                        AgentMemoryView(agent: profile)
                    } label: {
                        Label("Memory", systemImage: "brain")
                    }
                } footer: {
                    Text("What this agent's threads are doing, its journal and its notes.")
                }
            }
            Section {
                TextField("Name, e.g. Claude Work", text: $profile.account.label)
                if profile.providerId == "claude" {
                    TextField("Claude folder, e.g. ~/.claude-\(folderHint)", text: optional(\.account.configDir))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
            } header: {
                Text("Account")
            } footer: {
                if profile.providerId == "claude" {
                    Text("Each agent keeps its own Claude Code sign-in in this folder on the machine (CLAUDE_CONFIG_DIR). Sign in once per machine with `CLAUDE_CONFIG_DIR=\(profile.claudeConfigDir ?? "~/.claude-\(folderHint)") claude login`. Leave it empty to use the machine's own login. Happier never stores Claude tokens.")
                } else {
                    Text("Sessions use the machine's own \(Agent.displayNames[profile.providerId] ?? profile.providerId) login.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New Agent" : profile.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true
                    var trimmed = profile
                    trimmed.name = trimmed.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        let saved = await store.saveAgentProfile(trimmed)
                        saving = false
                        if saved {
                            AppHaptics.success()
                            dismiss()
                        }
                    }
                }
                .disabled(!canSave)
            }
        }
    }

    /// "julian" for "Julián": a folder name hint from the agent's name.
    private var folderHint: String {
        let folded = profile.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let slug = folded.lowercased().filter { $0.isLetter || $0.isNumber }
        return slug.isEmpty ? "agent" : slug
    }

    /// A text field over an optional string: empty means none.
    private func optional(_ path: WritableKeyPath<AgentProfile, String?>) -> Binding<String> {
        Binding(get: { profile[keyPath: path] ?? "" },
                set: { profile[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
}

// MARK: - Memory

/// An agent's memory: what each of its threads is doing now, its journal and its Markdown notes.
/// Synced through the account's encrypted store; exportable as an Obsidian folder.
struct AgentMemoryView: View {
    @Environment(HappierStore.self) private var store
    let agent: AgentProfile
    @State private var editingNote: AgentMemory.Note?
    @State private var exporting = false
    @State private var exportError: String?

    private var memory: AgentMemory { store.agentMemories[agent.id] ?? AgentMemory() }

    private var journalByDay: [(day: String, entries: [AgentMemory.JournalEntry])] {
        Dictionary(grouping: memory.journal, by: \.day)
            .map { (day: $0.key, entries: $0.value.sorted { $0.at > $1.at }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        Form {
            if let error = store.agentMemoryError, store.agentMemories[agent.id] == nil {
                Text(error).foregroundStyle(.secondary)
            }
            if !memory.complete {
                Text("Only the first \(KVListing.maxRows) records of a kind could be read, so older entries aren't shown here or in the export.")
                    .foregroundStyle(.orange)
            }
            Section {
                if memory.now.isEmpty {
                    Text("No thread has reported yet.").foregroundStyle(.secondary)
                }
                ForEach(memory.now) { thread in
                    Button {
                        AppHaptics.light()
                        Task { await store.openRelatedSession(thread.sessionId) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(thread.text.isEmpty ? String(localized: "Working") : thread.text)
                                .foregroundStyle(.primary)
                            Text(nowDetail(thread))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            } header: {
                Text("Now")
            }
            Section {
                if memory.notes.isEmpty {
                    Text("No notes yet.").foregroundStyle(.secondary)
                }
                ForEach(memory.notes) { note in
                    Button {
                        AppHaptics.light()
                        editingNote = note
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(note.title.isEmpty ? String(localized: "Untitled") : note.title).foregroundStyle(.primary)
                            Text(note.markdown).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await store.deleteAgentNote(note, agentId: agent.id) }
                        }
                    }
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await store.deleteAgentNote(note, agentId: agent.id) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Notes")
                    Spacer()
                    Button("New Note", systemImage: "plus") {
                        AppHaptics.light()
                        editingNote = AgentMemory.Note(title: "", markdown: "")
                    }
                    .labelStyle(.iconOnly)
                }
            }
            ForEach(journalByDay, id: \.day) { group in
                Section(group.day) {
                    ForEach(group.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.text)
                            Text(Date(timeIntervalSince1970: entry.at / 1000), style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await store.deleteAgentJournalEntry(entry, agentId: agent.id) }
                            }
                        }
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await store.deleteAgentJournalEntry(entry, agentId: agent.id) }
                            }
                        }
                    }
                }
            }
            if journalByDay.isEmpty {
                Section("Journal") { Text("Nothing logged yet.").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("\(agent.label) Memory")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Export to Obsidian", systemImage: "square.and.arrow.up") {
                    AppHaptics.light()
                    exporting = true
                }
                .disabled(store.agentMemories[agent.id] == nil)
            }
        }
        .refreshable { await store.refreshAgentMemory(agentId: agent.id) }
        .task { await store.refreshAgentMemory(agentId: agent.id) }
        .fileExporter(isPresented: $exporting,
                      document: AgentMemoryFolder(agentName: agent.name, memory: memory),
                      contentType: .folder,
                      defaultFilename: AgentMemoryExport.folderName(agentName: agent.name)) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Couldn't Export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .sheet(item: $editingNote) { note in
            NavigationStack {
                AgentNoteEditor(note: note, agentId: agent.id)
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 560)
            #endif
        }
    }

    private func nowDetail(_ thread: AgentMemory.Now) -> String {
        let ago = Date(timeIntervalSince1970: thread.updatedAt / 1000).formatted(.relative(presentation: .named))
        let place = [thread.title, [thread.host, thread.directory].compactMap { $0 }.joined(separator: " ")]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
        return (place + [ago]).joined(separator: " · ")
    }
}

/// One note's title and Markdown body; `[[links]]` point at other notes by title.
private struct AgentNoteEditor: View {
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var note: AgentMemory.Note
    let agentId: String
    @State private var saving = false

    var body: some View {
        Form {
            Section("Title") {
                TextField("Title", text: $note.title)
            }
            Section {
                TextEditor(text: $note.markdown)
                    .font(.body.monospaced())
                    .frame(minHeight: 280)
            } header: {
                Text("Markdown")
            } footer: {
                Text("Link other notes with [[Note title]].")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(note.title.isEmpty ? String(localized: "Note") : note.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true
                    Task {
                        let saved = await store.saveAgentNote(note, agentId: agentId)
                        saving = false
                        if saved {
                            AppHaptics.success()
                            dismiss()
                        }
                    }
                }
                .disabled(saving || note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// The Obsidian export as a folder document for `.fileExporter`.
private struct AgentMemoryFolder: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    let agentName: String
    let memory: AgentMemory

    init(agentName: String, memory: AgentMemory) {
        self.agentName = agentName
        self.memory = memory
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        AgentMemoryExport.fileWrapper(agentName: agentName, memory: memory)
    }
}
