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

// MARK: - Tasks

/// Where the Tasks list shows: a sheet from the session list (iPhone), or the window's right-hand
/// panel beside the conversation (iPad and Mac), which stays open while a session opens in the middle.
enum TasksPresentation { case sheet, panel }

extension EnvironmentValues {
    /// True where the window shows Tasks in its right-hand panel instead of a sheet.
    @Entry var tasksPanelAvailable = false
}

/// Tasks for you and your agents (`task/<id>` in the UserKVStore), with filters by who it's for and
/// its status.
struct TasksView: View {
    var presentation: TasksPresentation = .sheet
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var assignee: AgentTask.AssigneeFilter = .all
    @State private var status: AgentTask.StatusFilter = .open
    @State private var creating = false

    private var visible: [AgentTask] { AgentTask.filter(store.tasks, assignee: assignee, status: status) }

    var body: some View {
        NavigationStack {
            List {
                if !store.tasksComplete {
                    Text("Only the first \(KVListing.maxRows) stored tasks could be read, so some may be missing here.")
                        .foregroundStyle(.orange)
                }
                if let error = store.tasksError {
                    Text(error).foregroundStyle(.secondary)
                }
                ForEach(visible) { task in
                    NavigationLink(value: task.id) { TaskRow(task: task) }
                }
            }
            #if os(iOS)
            .listStyle(.plain)
            #endif
            .overlay {
                if visible.isEmpty, store.tasksError == nil {
                    ContentUnavailableView("No Tasks", systemImage: "checklist",
                                           description: Text("Tasks for you and your agents show up here."))
                }
            }
            .navigationDestination(for: String.self) { id in
                // In the panel an opened session shows in the middle while the task stays here.
                TaskDetailView(taskId: id) { if presentation == .sheet { dismiss() } }
            }
            .refreshable { await refresh() }
            .task { await refresh() }
            .navigationTitle("Tasks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if presentation == .sheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) { filterMenu }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Task", systemImage: "plus") {
                        AppHaptics.light()
                        creating = true
                    }
                }
            }
            .sheet(isPresented: $creating) {
                NewTaskSheet()
                    #if os(macOS)
                    .frame(minWidth: 420, minHeight: 360)
                    #endif
            }
        }
    }

    private func refresh() async {
        await store.refreshTasks()
        if store.agentProfiles.isEmpty { await store.refreshAgentProfiles() }
    }

    private var filterMenu: some View {
        Menu {
            Picker("For", selection: $assignee) {
                Text("Everyone").tag(AgentTask.AssigneeFilter.all)
                Text("Me").tag(AgentTask.AssigneeFilter.me)
                ForEach(store.agentProfiles) { profile in
                    Text(profile.label).tag(AgentTask.AssigneeFilter.agent(profile.id))
                }
            }
            Picker("Status", selection: $status) {
                Text("Open").tag(AgentTask.StatusFilter.open)
                ForEach(AgentTask.Status.allCases) { status in
                    Text(status.label).tag(AgentTask.StatusFilter.only(status))
                }
                Text("All").tag(AgentTask.StatusFilter.all)
            }
        } label: {
            Label("Filter", systemImage: assignee == .all && status == .open
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }
}

private struct TaskRow: View {
    let task: AgentTask

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title)
                .strikethrough(task.status == .done)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(task.assignee.label)
                Text("·")
                Text(task.status.label)
                if let due = task.due() {
                    Text("·")
                    Text(due.text).foregroundStyle(due.overdue && task.status != .done ? Color.red : Color.secondary)
                }
                if let folder = task.directory.map({ ($0 as NSString).lastPathComponent }), !folder.isEmpty {
                    Text("·")
                    Text(folder).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Who a task can be for: you or one of your agents.
private struct TaskAssigneePicker: View {
    @Binding var assignee: AgentTask.Assignee
    let agents: [AgentProfile]

    var body: some View {
        Picker("For", selection: $assignee) {
            Text("Me").tag(AgentTask.Assignee.user)
            ForEach(agents) { profile in
                Text(profile.label).tag(AgentTask.Assignee.agent(profile))
            }
            // An agent this device doesn't know (deleted or not loaded yet) stays selectable as it is.
            if case .agent(let id, _, _) = assignee, !agents.contains(where: { $0.id == id }) {
                Text(assignee.label.isEmpty ? id : assignee.label).tag(assignee)
            }
        }
    }
}

/// An optional date: a toggle, then the picker.
private struct TaskDateField: View {
    let title: LocalizedStringKey
    @Binding var ms: Double?

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { ms != nil },
            set: { on in ms = on ? (ms ?? ServerClock.nowMs() + 86_400_000) : nil }))
        if let current = ms {
            DatePicker(title, selection: Binding(
                get: { Date(timeIntervalSince1970: current / 1000) },
                set: { ms = ($0.timeIntervalSince1970 * 1000).rounded(.down) }))
                .labelsHidden()
        }
    }
}

private struct NewTaskSheet: View {
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var task = AgentTask(title: "")
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $task.title)
                    TextField("What needs to happen", text: Binding(get: { task.description ?? "" },
                                                                   set: { task.description = $0.isEmpty ? nil : $0 }),
                              axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    TaskAssigneePicker(assignee: $task.assignee, agents: store.agentProfiles)
                    TaskDateField(title: "Due", ms: $task.dueAt)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saving = true
                        Task {
                            let saved = await store.createTask(task)
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
        }
    }
}

/// One task: every field editable, its comments and history, the sessions that worked on it, and
/// "Assign to…", which hands it to an agent and starts that agent on it.
private struct TaskDetailView: View {
    let taskId: String
    /// Leaves the Tasks sheet, so an opened session is on screen.
    let close: () -> Void
    @Environment(HappierStore.self) private var store
    @State private var draft: AgentTask?
    @State private var comment = ""
    @State private var confirmDelete = false
    @State private var assigning = false
    @State private var alert: String?
    @State private var approveFolder: (agent: AgentProfile, machineId: String, directory: String)?

    private var stored: AgentTask? { store.task(id: taskId) }
    private var changes: AgentTask.Update? {
        guard let stored, let draft else { return nil }
        let update = AgentTask.Update(from: stored, to: draft)
        return update.isEmpty ? nil : update
    }

    var body: some View {
        Group {
            if let draft = Binding($draft) {
                form(draft)
            } else {
                ContentUnavailableView("Task Not Found", systemImage: "checklist",
                                       description: Text("It may have been deleted on another device."))
            }
        }
        .onAppear { if draft == nil { draft = stored } }
        .onChange(of: stored) { _, latest in
            // Someone else's change shows up here unless this screen has unsaved edits.
            if changes == nil { draft = latest }
        }
        .navigationTitle(draft?.title ?? "Task")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    guard let changes else { return }
                    Task { if let saved = await store.updateTask(id: taskId, changes) { draft = saved } }
                }
                .disabled(changes == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("Assign to…") {
                        ForEach(store.agentProfiles) { profile in
                            Button(profile.label) { assign(to: profile) }
                        }
                    }
                } label: {
                    Label("Assign to…", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(store.agentProfiles.isEmpty || assigning || changes != nil)
            }
        }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await store.deleteTask(id: taskId) } }
        }
        .alert("Assign to…", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
        .alert("Create the folder?", isPresented: Binding(get: { approveFolder != nil }, set: { if !$0 { approveFolder = nil } })) {
            Button("Create and Start") {
                guard let pending = approveFolder else { return }
                start(pending.agent, machineId: pending.machineId, directory: pending.directory, approve: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(approveFolder?.directory ?? "")
        }
    }

    private func form(_ task: Binding<AgentTask>) -> some View {
        Form {
            Section {
                TextField("Title", text: task.title)
                TextField("What was asked", text: Binding(get: { task.wrappedValue.description ?? "" },
                                                          set: { task.wrappedValue.description = $0.isEmpty ? nil : $0 }),
                          axis: .vertical)
                    .lineLimit(3...12)
            }
            Section {
                TaskAssigneePicker(assignee: task.assignee, agents: store.agentProfiles)
                Picker("Status", selection: task.status) {
                    ForEach(AgentTask.Status.allCases) { Text($0.label).tag($0) }
                }
                if let due = task.wrappedValue.due(), task.wrappedValue.status != .done {
                    Text(due.text).foregroundStyle(due.overdue ? Color.red : Color.secondary)
                }
            }
            Section("Dates") {
                TaskDateField(title: "Starts", ms: task.startAt)
                TaskDateField(title: "Due", ms: task.dueAt)
            }
            Section {
                Picker("Machine", selection: Binding(get: { task.wrappedValue.machineId ?? "" },
                                                     set: { task.wrappedValue.machineId = $0.isEmpty ? nil : $0 })) {
                    Text("Any").tag("")
                    ForEach(store.machines) { Text($0.name).tag($0.id) }
                    if let id = task.wrappedValue.machineId, !store.machines.contains(where: { $0.id == id }) { Text(id).tag(id) }
                }
                TextField("Folder", text: Binding(get: { task.wrappedValue.directory ?? "" },
                                                  set: { task.wrappedValue.directory = $0.isEmpty ? nil : $0 }))
                    .autocorrectionDisabled()
            } header: {
                Text("Where")
            } footer: {
                Text("Assign to… starts the agent here; without a folder it uses the machine's latest folder.")
            }
            sourceSection(task)
            TaskRepeatSections(task: task.wrappedValue, close: close)
            Section("Comment") {
                TextField("Add a comment", text: $comment, axis: .vertical)
                Button("Add Comment") {
                    let text = comment
                    comment = ""
                    Task { if let saved = await store.updateTask(id: taskId, AgentTask.Update(comment: text)) { draft = saved } }
                }
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !task.wrappedValue.threads.isEmpty {
                Section("Sessions") {
                    ForEach(task.wrappedValue.threads, id: \.self) { sessionId in
                        Button {
                            Task { await store.openRelatedSession(sessionId) }
                            close()
                        } label: {
                            Text(store.sessions[sessionId]?.title ?? sessionId).lineLimit(1)
                        }
                    }
                }
            }
            if !task.wrappedValue.log.isEmpty {
                Section("History") {
                    ForEach(Array(task.wrappedValue.log.enumerated().reversed()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            if let text = entry.text { Text(text) }
                            HStack(spacing: 4) {
                                Text(who(entry))
                                if let status = entry.status { Text("→ \(status.label)") }
                                Text(Date(timeIntervalSince1970: entry.at / 1000), style: .relative)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("Delete Task", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
    }

    private func sourceSection(_ task: Binding<AgentTask>) -> some View {
        let source = Binding(get: { task.wrappedValue.source ?? AgentTask.Source() },
                             set: { next in
                                 let empty = (next.label ?? "").isEmpty && (next.url ?? "").isEmpty && next.sessionId == nil
                                 task.wrappedValue.source = empty ? nil : next
                             })
        return Section("Where It Came From") {
            Picker("Kind", selection: source.kind) {
                Text("Chat").tag("chat")
                Text("Email").tag("email")
                Text("Session").tag("session")
                Text("Other").tag("other")
            }
            TextField("Label", text: Binding(get: { source.wrappedValue.label ?? "" },
                                             set: { source.wrappedValue.label = $0.isEmpty ? nil : $0 }))
            TextField("Link", text: Binding(get: { source.wrappedValue.url ?? "" },
                                            set: { source.wrappedValue.url = $0.isEmpty ? nil : $0 }))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            if let link = source.wrappedValue.url.flatMap(URL.init(string:)), link.scheme != nil {
                Link("Open Link", destination: link)
            }
            if let sessionId = source.wrappedValue.sessionId {
                Button("Open Session") {
                    Task { await store.openRelatedSession(sessionId) }
                    close()
                }
            }
        }
    }

    private func who(_ entry: AgentTask.LogEntry) -> String {
        if entry.byUser { return String(localized: "You") }
        if let id = entry.by["agentId"]?.stringValue {
            return store.agentProfile(id: id)?.label ?? String(localized: "An agent")
        }
        return String(localized: "A session")
    }

    /// The task's machine (or the first one online) and folder (or that machine's latest one).
    private func assign(to agent: AgentProfile) {
        guard let task = stored else { return }
        let machine = store.machines.first { $0.id == task.machineId } ?? store.machines.first { $0.active }
        guard let machine else {
            alert = String(localized: "No machine is online to start \(agent.name) on. Choose the task's machine when one is connected.")
            return
        }
        let directory = task.directory
            ?? Machine.recentDirectories(machineId: machine.id, sessions: Array(store.sessions.values)).first
            ?? machine.homeDir
        guard let directory, !directory.isEmpty else {
            alert = String(localized: "Set the task's folder first, so \(agent.name) knows where to work.")
            return
        }
        start(agent, machineId: machine.id, directory: directory, approve: false)
    }

    private func start(_ agent: AgentProfile, machineId: String, directory: String, approve: Bool) {
        assigning = true
        Task {
            let outcome = await store.assignTask(id: taskId, to: agent, machineId: machineId, directory: directory, approveNewDirectory: approve)
            assigning = false
            draft = store.task(id: taskId)
            switch outcome {
            case .created: close()
            case .needsDirectoryApproval(let path): approveFolder = (agent, machineId, path)
            case .failed(let message): alert = message
            }
        }
    }
}

/// "Repeat": the task's rules (one Automation each), time zone, thread continuity, next run,
/// Pause/Resume, Run now, and each occurrence's result. Saved on its own, because saving it also
/// creates or updates the Automations on the relay.
private struct TaskRepeatSections: View {
    let task: AgentTask
    let close: () -> Void
    @Environment(HappierStore.self) private var store
    @State private var draft: TaskRecurrence?
    @State private var editingRule: TaskRecurrence.Rule?
    @State private var saving = false
    @State private var termsWarning: TaskRecurrence?

    private var stored: TaskRecurrence? { task.recurrence }
    private var agent: AgentProfile? { task.assignee.agentId.flatMap { store.agentProfile(id: $0) } }

    var body: some View {
        Group {
            if let recurrence = draft {
                rulesSection(recurrence)
                optionsSection(recurrence)
            } else {
                Section("Repeat") {
                    Button("Repeat This Task…") {
                        draft = TaskRecurrence(rules: [TaskRecurrence.Rule(kind: .weekly([1, 2, 3, 4, 5]), hour: 9, minute: 0)])
                    }
                }
            }
            if !task.occurrences.isEmpty { occurrencesSection }
        }
        .onAppear { draft = stored }
        .onChange(of: stored) { _, latest in if !saving { draft = latest } }
        .sheet(item: $editingRule) { rule in
            NavigationStack {
                TaskRuleEditor(rule: rule) { edited in
                    guard var recurrence = draft else { return }
                    if let index = recurrence.rules.firstIndex(where: { $0.id == edited.id }) { recurrence.rules[index] = edited }
                    else { recurrence.rules.append(edited) }
                    draft = recurrence
                }
            }
            #if os(macOS)
            .frame(minWidth: 380, minHeight: 420)
            #endif
        }
        .alert("Automated Access with Claude", isPresented: Binding(get: { termsWarning != nil }, set: { if !$0 { termsWarning = nil } })) {
            Button("Continue") {
                guard let pending = termsWarning else { return }
                termsWarning = nil
                save(pending, warned: true)
            }
            Button("Cancel", role: .cancel) { termsWarning = nil }
        } message: {
            Text("""
            Repeating work runs without you, which is automated access. Anthropic's Consumer Terms (section 3.7) ask for an \
            API key for that, not a Claude subscription. If \(agent?.name ?? "this agent") signs in with a subscription, \
            consider assigning the task to a Codex agent instead.
            """)
        }
    }

    private func rulesSection(_ recurrence: TaskRecurrence) -> some View {
        Section {
            ForEach(recurrence.rules) { rule in
                Button {
                    editingRule = rule
                } label: {
                    Text(rule.summary).foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                guard var next = draft, next.rules.count > offsets.count else { return }
                next.rules.remove(atOffsets: offsets)
                draft = next
            }
            Button("Add Rule") { editingRule = TaskRecurrence.Rule(kind: .weekly([6, 0]), hour: 16, minute: 0) }
        } header: {
            Text("Repeat")
        } footer: {
            if let problem = store.recurrenceProblem(for: task) {
                Text(problem).foregroundStyle(.orange)
            } else if recurrence.paused {
                Text("Paused.")
            } else if let next = recurrence.nextRun() {
                Text("Next run: \(next.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }

    private func optionsSection(_ recurrence: TaskRecurrence) -> some View {
        Section {
            Picker("Time Zone", selection: Binding(get: { recurrence.timezone }, set: { draft?.timezone = $0 })) {
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                if !TimeZone.knownTimeZoneIdentifiers.contains(recurrence.timezone) { Text(recurrence.timezone).tag(recurrence.timezone) }
            }
            Picker("Each Time", selection: Binding(get: { recurrence.continuity }, set: { draft?.continuity = $0 })) {
                ForEach(TaskRecurrence.Continuity.allCases) { Text($0.label).tag($0) }
            }
            if draft != stored {
                Button(saving ? "Saving…" : "Save Repeat") { save(recurrence, warned: false) }
                    .disabled(saving || store.recurrenceProblem(for: task) != nil)
                if stored != nil { Button("Discard Changes") { draft = stored } }
            }
            if let stored, draft == stored {
                Button(stored.paused ? "Resume" : "Pause") {
                    var next = stored
                    next.paused.toggle()
                    save(next, warned: next.paused)
                }
                .disabled(saving)
                Button("Run Now") { Task { await store.runRecurrenceNow(taskId: task.id) } }
                    .disabled(saving || stored.paused)
            }
            if stored != nil || draft != nil {
                Button("Stop Repeating", role: .destructive) {
                    if stored == nil { draft = nil } else { save(nil, warned: true) }
                }
                .disabled(saving)
            }
        } footer: {
            Text("Each rule fires on \(machineName) in \(task.directory ?? "the task's folder"). If the previous occurrence is still running, the new one is skipped and shows here as skipped.")
        }
    }

    private var machineName: String {
        task.machineId.flatMap { id in store.machines.first { $0.id == id }?.name } ?? String(localized: "the task's machine")
    }

    private var occurrencesSection: some View {
        Section("Occurrences") {
            ForEach(task.occurrences.reversed()) { occurrence in
                Button {
                    guard let sessionId = occurrence.sessionId else { return }
                    Task { await store.openRelatedSession(sessionId) }
                    close()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(occurrence.status.label)
                                .foregroundStyle(occurrence.status == .failed || occurrence.status == .interrupted ? Color.red : Color.primary)
                            Spacer()
                            Text(Date(timeIntervalSince1970: occurrence.startedAt / 1000).formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        let rule = task.recurrence?.rules.first { $0.id == occurrence.ruleId }?.summary
                        let details = [rule, occurrence.note].compactMap { $0 }
                        if !details.isEmpty { Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(occurrence.sessionId == nil)
            }
        }
    }

    /// Starting (or resuming) repetition for a Claude agent warns first about automated access.
    private func save(_ recurrence: TaskRecurrence?, warned: Bool) {
        let starts = recurrence.map { !$0.paused && (stored == nil || stored?.paused == true) } ?? false
        if !warned, starts, TaskRecurrence.needsAutomatedAccessWarning(providerId: agent?.providerId) {
            termsWarning = recurrence
            return
        }
        saving = true
        Task {
            let saved = await store.saveRecurrence(taskId: task.id, recurrence)
            saving = false
            if saved != nil { draft = recurrence == nil ? nil : saved?.recurrence }
        }
    }
}

/// One rule: weekly days and time, every N days from a date, or a day of the month.
private struct TaskRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: TaskRecurrence.Rule
    let save: (TaskRecurrence.Rule) -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case weekly, everyNDays, monthly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .weekly: String(localized: "Days of the Week")
            case .everyNDays: String(localized: "Every N Days")
            case .monthly: String(localized: "Day of the Month")
            }
        }
    }

    private var mode: Binding<Mode> {
        Binding(get: {
            switch rule.kind {
            case .weekly: .weekly
            case .everyNDays: .everyNDays
            case .monthly: .monthly
            }
        }, set: { next in
            switch next {
            case .weekly: rule.kind = .weekly([1, 2, 3, 4, 5])
            case .everyNDays: rule.kind = .everyNDays(1, anchorDate: Self.dayString(.now))
            case .monthly: rule.kind = .monthly(1)
            }
        })
    }

    private var time: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            rule.hour = parts.hour ?? 0
            rule.minute = parts.minute ?? 0
        })
    }

    private var valid: Bool {
        if case .weekly(let days) = rule.kind { return !days.isEmpty }
        return true
    }

    var body: some View {
        Form {
            Picker("Repeats", selection: mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            switch rule.kind {
            case .weekly(let days):
                Section("Days") {
                    // Monday first, as the week reads.
                    ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                        Toggle(Calendar.current.weekdaySymbols[day], isOn: Binding(get: { days.contains(day) }, set: { on in
                            var next = days
                            if on { next.insert(day) } else { next.remove(day) }
                            rule.kind = .weekly(next)
                        }))
                    }
                }
            case .everyNDays(let n, let anchor):
                Section {
                    Stepper("Every \(n) day\(n == 1 ? "" : "s")", value: Binding(get: { n }, set: { rule.kind = .everyNDays(max(1, $0), anchorDate: anchor) }), in: 1...365)
                    DatePicker("Starting", selection: Binding(get: { Self.day(anchor) ?? .now }, set: { rule.kind = .everyNDays(n, anchorDate: Self.dayString($0)) }),
                               displayedComponents: .date)
                }
            case .monthly(let day):
                Section {
                    Stepper("Day \(day)", value: Binding(get: { day }, set: { rule.kind = .monthly(min(31, max(1, $0))) }), in: 1...31)
                } footer: {
                    if day > 28 { Text("Months without day \(day) are skipped.") }
                }
            }
            DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
        }
        .formStyle(.grouped)
        .navigationTitle("Rule")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    save(rule)
                    dismiss()
                }
                .disabled(!valid)
            }
        }
    }

    private static func dayString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }

    private static func day(_ string: String) -> Date? {
        let pieces = string.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2]))
    }
}
