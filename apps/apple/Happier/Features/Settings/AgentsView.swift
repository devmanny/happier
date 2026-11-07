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
                    editing = AgentProfile(name: "", providerId: "claude", account: .init(label: ""))
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

/// "Julián", its engine, and the account it's tied to; the engine's logo in place of an avatar.
struct AgentProfileRow: View {
    let profile: AgentProfile
    var selected = false
    @Environment(HappierStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            ProviderLogo(providerId: profile.providerId)
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
struct AgentEditor: View {
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
            // The emoji an agent may carry stays in its identity, unedited and never drawn here.
            Section("Name") {
                TextField("Name", text: $profile.name)
                    .accessibilityIdentifier("agent-name")
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
    /// The conversation open beside the list (nil on the iPhone's sheet or with none open). Tasks
    /// belong to the account; this only decides what is shown as linked to it.
    var openSessionId: String?
    /// Only this session's tasks (the iPhone chat's ⓘ menu): no scope picker, no other groups.
    var onlyThisSession = false
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var assignee: AgentTask.AssigneeFilter
    @State private var status: AgentTask.StatusFilter = .open
    @State private var scope: AgentTask.Scope = .all
    @State private var showCompleted = false
    @State private var showArchived = false
    /// Completed with the circle moments ago: still shown, struck through, and can be undone.
    @State private var completions = TaskCompletions()
    @State private var selecting = false
    @State private var selection = Set<String>()
    /// The tasks "Assign…" (a swipe) is choosing for, and those "Other Session…" is picking for.
    @State private var assigning: [String] = []
    @State private var pickingSessionFor: [String] = []
    @State private var creating: AgentTask.Assignee?
    @State private var assigningExisting = false
    @State private var query = ""
    /// The in-memory search index, kept in step with the tasks as they change.
    @State private var taskSearch = TaskSearch()
    /// The task whose detail is open, when one is, with where it was opened from.
    @State private var path: [TaskRoute] = []

    /// `assignee` starts the list filtered to who the tasks are for (an agent's card opens its own).
    init(presentation: TasksPresentation = .sheet, openSessionId: String? = nil, onlyThisSession: Bool = false,
         assignee: AgentTask.AssigneeFilter = .all) {
        self.presentation = presentation
        self.openSessionId = openSessionId
        self.onlyThisSession = onlyThisSession
        _assignee = State(initialValue: assignee)
    }

    private var sections: [AgentTask.Section] {
        let shown = AgentTask.filter(store.tasks, assignee: assignee, status: status,
                                     showCompleted: showCompleted, showArchived: showArchived)
        // What the circle just completed stays until its time to undo passes.
        let shownIds = Set(shown.map(\.id)), lingering = completions.lingeringIds
        let completedHere = store.tasks.filter { lingering.contains($0.id) && !shownIds.contains($0.id) }
        return AgentTask.sections(shown + completedHere,
                                  scope: onlyThisSession ? .thisSession : openSessionId == nil ? .all : scope,
                                  openSessionId: openSessionId, status: .all, showCompleted: true, showArchived: true)
    }

    /// Search ignores the filter and the scope: every task, open first, then completed and archived.
    private var searchResults: [TaskSearch.Result] {
        let tasks = store.tasks
        taskSearch.sync(tasks, context: TaskSearch.Context(
            assigneeName: { store.taskAssigneeName($0) },
            sessionTitle: { store.sessions[$0]?.title },
            machineName: { id in store.machines.first { $0.id == id }?.name }))
        return taskSearch.search(query, in: tasks)
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let sections = isSearching ? [] : sections
        let results = isSearching ? searchResults : []
        NavigationStack(path: $path) {
            List(selection: selecting ? $selection : nil) {
                if isSearching {
                    ForEach(results) { result in
                        NavigationLink(value: TaskRoute(id: result.id, origin: listOrigin)) {
                            TaskRow(task: result.task, openSessionId: openSessionId, match: result) { open($0) }
                        }
                        .tag(result.id)
                        .contextMenu { rowMenu(result.task) }
                    }
                }
                if openSessionId != nil, !onlyThisSession {
                    Picker("Show", selection: $scope) {
                        Text("All").tag(AgentTask.Scope.all)
                        Text("This Session").tag(AgentTask.Scope.thisSession)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowSeparator(.hidden)
                }
                if !store.tasksComplete {
                    Text("Only the first \(KVListing.maxRows) stored tasks could be read, so some may be missing here.")
                        .foregroundStyle(.orange)
                }
                if let error = store.tasksError {
                    Text(error).foregroundStyle(.secondary)
                }
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    Section {
                        ForEach(section.tasks) { task in
                            NavigationLink(value: TaskRoute(id: task.id, origin: listOrigin)) {
                                TaskRow(task: task, openSessionId: openSessionId,
                                        completedHere: completions.lingeringIds.contains(task.id),
                                        toggleDone: selecting ? nil : { toggleDone(task) }) { open($0) }
                            }
                            .tag(task.id)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if task.completesFromList {
                                    Button("Complete", systemImage: "checkmark") { toggleDone(task) }
                                        .tint(.gray)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                archiveButton([task.id], archived: task.isArchived)
                                    .tint(.gray)
                                Button("Assign…", systemImage: "person.crop.circle.badge.plus") { assigning = [task.id] }
                                    .tint(Color(white: 0.6))
                            }
                            .contextMenu { rowMenu(task) }
                        }
                    } header: {
                        header(section, isFirstGroup: sections.firstIndex { $0.kind != .linkedToOpenSession } == index)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.plain)
            .environment(\.editMode, .constant(selecting ? .active : .inactive))
            #endif
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar }
            }
            .confirmationDialog("Assign to…", isPresented: Binding(get: { !assigning.isEmpty }, set: { if !$0 { assigning = [] } }),
                                titleVisibility: .visible) {
                let ids = assigning
                ForEach(store.agentProfiles) { profile in
                    Button(profile.label) { assign(ids, .agent(profile)) }
                }
                if let openSessionId, let session = store.sessions[openSessionId] {
                    Button("This Session · \(session.title)") { assign(ids, .session(id: session.id, title: session.title)) }
                }
                Button("Other Session…") { pickingSessionFor = ids }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: Binding(get: { !pickingSessionFor.isEmpty }, set: { if !$0 { pickingSessionFor = [] } })) {
                let ids = pickingSessionFor
                TaskSessionPicker(excluding: nil) { session in assign(ids, .session(id: session.id, title: session.title)) }
            }
            .overlay {
                if isSearching {
                    if results.isEmpty { ContentUnavailableView.search(text: query) }
                } else if sections.isEmpty, store.tasksError == nil {
                    if onlyThisSession {
                        ContentUnavailableView("No Open Tasks Here", systemImage: "link",
                                               description: Text("Tasks linked to this session show up here; all your tasks are in Tasks."))
                    } else if scope == .thisSession, openSessionId != nil {
                        ContentUnavailableView {
                            Label("No Tasks Linked to This Session", systemImage: "link")
                        } description: {
                            Text("Tasks belong to your account; the rest are in All.")
                        } actions: {
                            Button("Show All") { scope = .all }
                        }
                    } else {
                        ContentUnavailableView("No Tasks", systemImage: "checklist",
                                               description: Text("Tasks for you and your agents show up here."))
                    }
                }
            }
            .navigationDestination(for: TaskRoute.self) { route in
                // In the panel an opened session shows in the middle while the task stays here.
                TaskDetailView(taskId: route.id, origin: route.origin) { if presentation == .sheet { dismiss() } }
            }
            .refreshable { await refresh() }
            .task { await refresh() }
            // A request from the My Tasks widget or a link: show that task, or the list.
            .onChange(of: store.tasksRequest, initial: true) { _, request in
                guard let request else { return }
                switch request {
                case .list: path = []
                case .task(let id): path = [TaskRoute(id: id, origin: .link)]
                }
                store.tasksRequest = nil
            }
            .searchable(text: $query, prompt: "Search Tasks")
            .navigationTitle(onlyThisSession ? "Session Tasks" : "Tasks")
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
                    Button(selecting ? "Done" : "Select") {
                        AppHaptics.light()
                        withAnimation(.smooth) { selecting.toggle() }
                        selection = []
                    }
                    .disabled(!selecting && sections.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    if let thisSession {
                        Menu {
                            Button("New Task for This Session", systemImage: "plus") { create(for: thisSession) }
                            Button("Assign Existing Task Here…", systemImage: "arrow.down.to.line") { assigningExisting = true }
                            Divider()
                            Button("New Task", systemImage: "checklist") { create(for: .user) }
                        } label: {
                            Label("New Task", systemImage: "plus")
                        }
                    } else {
                        Button("New Task", systemImage: "plus") { create(for: .user) }
                    }
                }
            }
            .sheet(item: Binding(get: { creating.map(PresetAssignee.init) }, set: { creating = $0?.assignee })) { preset in
                NewTaskSheet(assignee: preset.assignee, openSessionId: openSessionId)
                    #if os(macOS)
                    .frame(minWidth: 420, minHeight: 360)
                    #endif
            }
            .sheet(isPresented: $assigningExisting) {
                if let thisSession { TaskPickerSheet(assignee: thisSession) }
            }
        }
    }

    /// A task opened from this list: from inside the open session (its tasks, or the panel beside
    /// it), else from the account's list.
    private var listOrigin: AgentTask.Origin {
        openSessionId.map(AgentTask.Origin.session) ?? .list
    }

    /// The open session as an assignee, while the list shows this session's tasks.
    private var thisSession: AgentTask.Assignee? {
        guard let openSessionId, onlyThisSession || scope == .thisSession else { return nil }
        return .session(id: openSessionId, title: store.sessions[openSessionId]?.title)
    }

    private func create(for assignee: AgentTask.Assignee) {
        AppHaptics.light()
        creating = assignee
    }

    /// "Linked to this session", then "All tasks" grouped by who each task is for.
    @ViewBuilder
    private func header(_ section: AgentTask.Section, isFirstGroup: Bool) -> some View {
        switch section.kind {
        case .linkedToOpenSession:
            Label("Linked to This Session · \(section.tasks.count)", systemImage: "link")
        case .assignee(let assignee):
            let who = assignee == .user ? String(localized: "You") : store.taskAssigneeName(assignee)
            Text(isFirstGroup ? "All Tasks · \(who) · \(section.tasks.count)" : "\(who) · \(section.tasks.count)")
        }
    }

    /// Opens a linked session in the middle; the sheet gets out of the way, the panel stays.
    private func open(_ sessionId: String) {
        Task { await store.openRelatedSession(sessionId) }
        if presentation == .sheet { dismiss() }
    }

    private func refresh() async {
        await store.refreshTasks()
        if store.agentProfiles.isEmpty { await store.refreshAgentProfiles() }
    }

    /// Sessions some task is assigned to, for the filter.
    private var assignedSessionIds: [String] {
        var seen = Set<String>()
        return store.tasks.compactMap(\.assignee.sessionId).filter { seen.insert($0).inserted }
    }

    // MARK: Quick actions (as in Reminders)

    /// The circle: completes the task (it stays struck through for a moment), or undoes that.
    private func toggleDone(_ task: AgentTask) {
        if completions.lingeringIds.contains(task.id) {
            guard let undo = completions.undo(task.id) else { return }
            AppHaptics.light()
            Task { await store.updateTask(id: task.id, undo) }
            return
        }
        guard let done = completions.complete(task, now: ServerClock.nowMs()) else { return }
        AppHaptics.success()
        Task { await store.updateTask(id: task.id, done) }
        Task {
            try? await Task.sleep(for: .milliseconds(Int(TaskCompletions.lingerMs) + 100))
            withAnimation(.smooth) { completions.expire(now: ServerClock.nowMs()) }
        }
    }

    private func archiveButton(_ ids: [String], archived: Bool) -> some View {
        Button(archived ? "Unarchive" : "Archive", systemImage: archived ? "tray.and.arrow.up" : "archivebox") {
            AppHaptics.light()
            selection = []
            Task { await store.updateTasks(ids: ids, .archiving(!archived)) }
        }
    }

    private func assign(_ ids: [String], _ assignee: AgentTask.Assignee) {
        AppHaptics.selection()
        selection = []
        Task { await store.updateTasks(ids: ids, .assigning(assignee)) }
    }

    /// "Assign to…": the same agents and sessions as the task's detail; it only assigns.
    @ViewBuilder private func assignItems(_ ids: [String]) -> some View {
        if !store.agentProfiles.isEmpty {
            Section("Agents") {
                ForEach(store.agentProfiles) { profile in
                    Button { assign(ids, .agent(profile)) } label: {
                        Label { Text(profile.label) } icon: { ProviderLogo.menuImage(profile.providerId) }
                    }
                }
            }
        }
        Section("Sessions") {
            if let openSessionId, let session = store.sessions[openSessionId] {
                Button("This Session · \(session.title)") { assign(ids, .session(id: session.id, title: session.title)) }
            }
            Button("Other Session…", systemImage: "magnifyingglass") { pickingSessionFor = ids }
        }
    }

    @ViewBuilder private func rowMenu(_ task: AgentTask) -> some View {
        if task.completesFromList {
            Button("Complete", systemImage: "checkmark.circle") { toggleDone(task) }
        }
        Menu {
            assignItems([task.id])
        } label: {
            Label("Assign to…", systemImage: "person.crop.circle.badge.plus")
        }
        archiveButton([task.id], archived: task.isArchived)
        Divider()
        Button("Open", systemImage: "arrow.up.forward.square") {
            path.append(TaskRoute(id: task.id, origin: listOrigin))
        }
    }

    /// While selecting: complete, assign or archive the chosen tasks together.
    private var selectionBar: some View {
        let chosen = store.tasks.filter { selection.contains($0.id) }
        let completable = chosen.filter(\.completesFromList).map(\.id)
        return HStack(spacing: 12) {
            Button("Complete", systemImage: "checkmark.circle") {
                AppHaptics.success()
                selection = []
                Task { await store.updateTasks(ids: completable, AgentTask.Update(status: .done)) }
            }
            .disabled(completable.isEmpty)
            Spacer()
            Text("\(chosen.count) selected").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Menu {
                assignItems(chosen.map(\.id))
            } label: {
                Label("Assign", systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(chosen.isEmpty)
            archiveButton(chosen.map(\.id), archived: !chosen.isEmpty && chosen.allSatisfy(\.isArchived))
                .disabled(chosen.isEmpty)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var filterMenu: some View {
        Menu {
            Picker("For", selection: $assignee) {
                Text("Everyone").tag(AgentTask.AssigneeFilter.all)
                Text("Me").tag(AgentTask.AssigneeFilter.me)
                ForEach(store.agentProfiles) { profile in
                    Text(profile.label).tag(AgentTask.AssigneeFilter.agent(profile.id))
                }
                ForEach(assignedSessionIds, id: \.self) { id in
                    Text(store.taskAssigneeName(.session(id: id, title: nil))).tag(AgentTask.AssigneeFilter.session(id))
                }
            }
            Picker("Status", selection: $status) {
                Text("Open").tag(AgentTask.StatusFilter.open)
                ForEach(AgentTask.Status.allCases) { status in
                    Text(status.label).tag(AgentTask.StatusFilter.only(status))
                }
                Text("All").tag(AgentTask.StatusFilter.all)
            }
            Section {
                Toggle("Show Completed", isOn: $showCompleted)
                Toggle("Show Archived", isOn: $showArchived)
            }
        } label: {
            Label("Filter", systemImage: assignee == .all && status == .open && !showCompleted && !showArchived
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }
}

private struct TaskRow: View {
    let task: AgentTask
    var openSessionId: String?
    /// Completed with the circle moments ago (can be undone).
    var completedHere = false
    /// The circle's action; nil while selecting.
    var toggleDone: (() -> Void)?
    /// A search result: what matched in the title, and a piece of the field that matched otherwise.
    var match: TaskSearch.Result?
    var openSession: (String) -> Void = { _ in }
    @Environment(HappierStore.self) private var store

    /// The sessions it is linked to, shortly named and tappable; the open one marked.
    @ViewBuilder private var sessions: some View {
        let linked = task.linkedSessions
        if linked.isEmpty {
            Label("No session", systemImage: "link").labelStyle(.titleAndIcon).foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.tertiary)
                ForEach(linked.prefix(2)) { link in
                    Button {
                        openSession(link.sessionId)
                    } label: {
                        HStack(spacing: 3) {
                            if link.sessionId == openSessionId {
                                Image(systemName: "smallcircle.filled.circle").foregroundStyle(Color.userBubble)
                            }
                            Text(Self.shortName(store.sessions[link.sessionId]?.title ?? link.sessionId))
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(link.sessionId == openSessionId ? "Open session (this one)" : "Open session")
                }
                if linked.count > 2 { Text("+\(linked.count - 2)").foregroundStyle(.secondary) }
            }
        }
    }

    /// The matched words in bold (no color: a match isn't a state).
    private func highlighted(_ text: String, _ ranges: [Range<String.Index>]) -> AttributedString {
        var result = AttributedString(text)
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }

    static func shortName(_ title: String) -> String {
        title.count > 22 ? String(title.prefix(21)) + "…" : title
    }

    /// The leading circle: completes an open task; a repeating or archived task shows why it doesn't.
    @ViewBuilder private var circle: some View {
        let done = task.status == .done || completedHere
        if task.isArchived {
            Image(systemName: "archivebox").foregroundStyle(.tertiary)
                .accessibilityLabel("Archived")
        } else if task.recurrence != nil, !done {
            Image(systemName: "repeat.circle").foregroundStyle(.tertiary)
                .accessibilityLabel("Repeats; archive or pause it instead")
        } else if let toggleDone, task.completesFromList || completedHere {
            Button(action: toggleDone) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(done ? "Mark as not done" : "Complete")
        } else {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(.tertiary)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            circle.font(.title3)
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(highlighted(task.title, match?.titleHighlights ?? []))
                .strikethrough(task.status == .done || completedHere)
                .foregroundStyle(completedHere ? .secondary : .primary)
                .lineLimit(2)
            if let snippet = match?.snippet {
                (Text("\(snippet.field.label): ").foregroundStyle(.tertiary) + Text(highlighted(snippet.snippet.text, snippet.snippet.highlights)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                if task.assignee.sessionId != nil {
                    Text("Session · \(Self.shortName(store.taskAssigneeName(task.assignee)))")
                } else {
                    Text(task.assignee.label)
                }
                Text("·")
                Text(task.status.label)
                if task.isArchived {
                    Text("·")
                    Text("Archived")
                }
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
            sessions
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// How every start of the task runs ("Start Now", "Schedule…", each repeat), with the composer's
/// single permission symbol (YOLO in amber).
private struct TaskPermissionPicker: View {
    @Binding var mode: PermissionMode
    let agentId: String?

    var body: some View {
        LabeledContent("Permissions") {
            Menu {
                Picker("Permissions", selection: $mode) {
                    ForEach(PermissionMode.allCases, id: \.self) { option in
                        Label { Text(option.label(agentId: agentId)) } icon: { Image(systemName: PermissionSymbol.name(option)) }
                            .tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    PermissionSymbol(mode: mode)
                    Text(mode.label(agentId: agentId)).foregroundStyle(.secondary)
                }
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Permissions: \(mode.label(agentId: agentId))")
        }
    }
}

/// Who a task can be for: you or one of your agents.
private struct TaskAssigneePicker: View {
    @Binding var assignee: AgentTask.Assignee
    let agents: [AgentProfile]
    /// The session open beside the list, offered as an assignee.
    var openSessionId: String?
    /// The task is already worked in the open session: it isn't offered again, and who it is for
    /// reads "Mateo · this session".
    var worksInOpenSession = false
    /// The open session as somewhere new for it: not when the task is linked to it already.
    var offersOpenSession = true
    @Environment(HappierStore.self) private var store

    /// The current assignee's name, with where it works when that is the open session.
    private func name(_ candidate: AgentTask.Assignee, _ name: String) -> String {
        guard worksInOpenSession, candidate == assignee else { return name }
        return String(localized: "\(name) · this session")
    }

    var body: some View {
        Picker("For", selection: $assignee) {
            Text(name(.user, String(localized: "Me"))).tag(AgentTask.Assignee.user)
            ForEach(agents) { profile in
                let tag = assignee.agentId == profile.id ? assignee : AgentTask.Assignee.agent(profile)
                Label { Text(name(tag, profile.label)) } icon: { ProviderLogo.menuImage(profile.providerId) }
                    .tag(tag)
            }
            // An agent this device doesn't know (deleted or not loaded yet) stays selectable as it is.
            if case .agent(let id, _, _) = assignee, !agents.contains(where: { $0.id == id }) {
                Text(name(assignee, assignee.label.isEmpty ? id : assignee.label)).tag(assignee)
            }
            if let openSessionId, assignee.sessionId == openSessionId {
                Text("This Session").tag(assignee)
            } else if let openSessionId, offersOpenSession {
                let tag = AgentTask.Assignee.session(id: openSessionId, title: store.sessions[openSessionId]?.title)
                Text("This Session · \(store.taskAssigneeName(tag))").tag(tag)
            }
            if let id = assignee.sessionId, id != openSessionId {
                Text("Session · \(store.taskAssigneeName(assignee))").tag(assignee)
            }
        }
    }
}

extension HappierStore {
    /// Who a task is for, as shown: a session by its current title, then the one stored, then its id.
    func taskAssigneeName(_ assignee: AgentTask.Assignee) -> String {
        if let id = assignee.sessionId, let title = sessions[id]?.title { return title }
        return assignee.label
    }
}

/// A task's detail in the Tasks navigation, and where it was opened from.
private struct TaskRoute: Hashable {
    let id: String
    let origin: AgentTask.Origin
}

/// So a "New Task" sheet can be presented with who it is for already chosen.
private struct PresetAssignee: Identifiable {
    let assignee: AgentTask.Assignee
    var id: String { assignee.agentId.map { "agent:\($0)" } ?? assignee.sessionId.map { "session:\($0)" } ?? "user" }
}

/// "Assign Existing Task Here…": the account's open tasks not already for `assignee`; picking one
/// only assigns it.
private struct TaskPickerSheet: View {
    let assignee: AgentTask.Assignee
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [AgentTask] {
        AgentTask.filter(store.tasks, assignee: .all, status: .open)
            .filter { $0.assignee.sessionId == nil || $0.assignee.sessionId != assignee.sessionId }
            .filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(matches) { task in
                Button {
                    Task { await store.assignTask(id: task.id, to: assignee) }
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title).foregroundStyle(.primary).lineLimit(2)
                        Text("\(store.taskAssigneeName(task.assignee)) · \(task.status.label)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if matches.isEmpty { ContentUnavailableView("No Open Tasks", systemImage: "checklist") }
            }
            .searchable(text: $query)
            .navigationTitle("Assign a Task Here")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}

/// "Assign to…" → "Other Session…": every session, searchable by title or folder.
private struct TaskSessionPicker: View {
    var excluding: String?
    let pick: (Session) -> Void
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [Session] {
        store.sessionList.filter { session in
            session.id != excluding && (query.isEmpty || session.title.localizedStandardContains(query)
                                        || (session.path?.localizedStandardContains(query) ?? false))
        }
    }

    var body: some View {
        NavigationStack {
            List(matches) { session in
                Button {
                    pick(session)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title).foregroundStyle(.primary).lineLimit(1)
                            if let path = session.path {
                                Text(displayPath(path, machineId: session.machineId))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 0)
                        if let agentId = session.agentId { ProviderLogo(providerId: agentId) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if matches.isEmpty { ContentUnavailableView("No Sessions", systemImage: "bubble.left.and.bubble.right") }
            }
            .searchable(text: $query)
            .navigationTitle("Assign to a Session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    private func displayPath(_ path: String, machineId: String?) -> String {
        if let home = store.machines.first(where: { $0.id == machineId })?.homeDir, path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
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
    @State private var task: AgentTask
    @State private var saving = false
    private let openSessionId: String?

    init(assignee: AgentTask.Assignee = .user, openSessionId: String? = nil) {
        _task = State(initialValue: AgentTask(title: "", assignee: assignee))
        self.openSessionId = openSessionId
    }

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
                    TaskAssigneePicker(assignee: $task.assignee, agents: store.agentProfiles, openSessionId: openSessionId)
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

/// One task: every field editable, its comments and history, the sessions that worked on it,
/// "Assign to…" (an agent or a session; it only assigns), and, once assigned, "Start Now" and
/// "Schedule…" (a one-time start on the relay's Automations).
private struct TaskDetailView: View {
    let taskId: String
    /// Where it was opened from: inside a session, it shows what the task already does there
    /// instead of offering it again.
    var origin: AgentTask.Origin = .list
    private var openSessionId: String? { origin.sessionId }
    /// Leaves the Tasks sheet, so an opened session is on screen.
    let close: () -> Void
    @Environment(HappierStore.self) private var store
    @State private var draft: AgentTask?
    @State private var comment = ""
    @State private var confirmDelete = false
    @State private var working = false
    @State private var alert: String?
    @State private var pickingSession = false
    /// The schedule sheet, opened at this date.
    @State private var scheduling: ScheduleDraft?
    /// A new scheduled start for a Claude agent, held until the Consumer Terms warning is answered.
    @State private var termsWarning: Date?
    @State private var approveFolder: (agent: AgentProfile, machineId: String, directory: String)?

    /// The task as it was when these edits started: what "changes" are measured against, so a
    /// change made elsewhere meanwhile is kept, not reverted, when this screen saves.
    @State private var base: AgentTask?
    /// The task changed elsewhere (an agent, another device) while this screen has unsaved edits.
    @State private var changedElsewhere = false

    private var stored: AgentTask? { store.task(id: taskId) }
    private var actions: AgentTask.Actions? { stored?.availableActions(from: origin) }
    private var changes: AgentTask.Update? {
        guard let base = base ?? stored, let draft else { return nil }
        let update = AgentTask.Update(from: base, to: draft)
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
        .onAppear {
            if draft == nil {
                draft = stored
                base = stored
            }
        }
        .onChange(of: stored) { _, latest in
            // Someone else's change shows up at once, unless this screen has unsaved edits: then it
            // says so and lets you choose, instead of overwriting what you're writing.
            if changes == nil {
                draft = latest
                base = latest
            } else if latest?.version != base?.version {
                changedElsewhere = true
            }
        }
        .safeAreaInset(edge: .top) {
            if changedElsewhere {
                HStack(spacing: 10) {
                    Label("This task changed while you were editing.", systemImage: "exclamationmark.arrow.circlepath")
                        .font(.subheadline)
                    Spacer(minLength: 0)
                    Button("Keep My Edits") { changedElsewhere = false }
                    Button("Load Changes") {
                        draft = stored
                        base = stored
                        changedElsewhere = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal)
            }
        }
        .navigationTitle(draft?.title ?? "Task")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    guard let changes else { return }
                    Task {
                        if let saved = await store.updateTask(id: taskId, changes) {
                            draft = saved
                            base = saved
                            changedElsewhere = false
                        }
                    }
                }
                .disabled(changes == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if !store.agentProfiles.isEmpty {
                        Section("Agents") {
                            ForEach(store.agentProfiles) { profile in
                                // Who it is for already: checked, not something to choose again.
                                Toggle(isOn: assigned(.agent(profile))) {
                                    Label { Text(profile.label) } icon: { ProviderLogo.menuImage(profile.providerId) }
                                }
                                .disabled(actions?.offers(.agent(profile)) == false)
                            }
                        }
                    }
                    Section("Sessions") {
                        if let openSessionId, let session = store.sessions[openSessionId] {
                            if actions?.offersThisSession == true {
                                Toggle("This Session · \(session.title)", isOn: assigned(.session(id: session.id, title: session.title)))
                            } else if actions?.worksHere == true {
                                Label("Working in this session", systemImage: "checkmark.circle")
                            }
                        }
                        Button("Other Session…", systemImage: "magnifyingglass") { pickingSession = true }
                    }
                } label: {
                    Label("Assign to…", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(working || changes != nil)
            }
        }
        .sheet(isPresented: $pickingSession) {
            TaskSessionPicker(excluding: nil) { session in assign(.session(id: session.id, title: session.title)) }
        }
        .sheet(item: $scheduling) { draft in
            TaskScheduleSheet(initial: draft.date, isChange: draft.isChange) { date in schedule(at: date, warned: false) }
        }
        .alert("Automated Access with Claude", isPresented: Binding(get: { termsWarning != nil }, set: { if !$0 { termsWarning = nil } })) {
            Button("Continue") {
                guard let pending = termsWarning else { return }
                termsWarning = nil
                schedule(at: pending, warned: true)
            }
            Button("Cancel", role: .cancel) { termsWarning = nil }
        } message: {
            Text("""
            A scheduled start runs without you, which is automated access. Anthropic's Consumer Terms (section 3.7) ask for an \
            API key for that, not a Claude subscription. If this agent signs in with a subscription, consider assigning the \
            task to a Codex agent instead.
            """)
        }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await store.deleteTask(id: taskId) } }
        }
        .alert("Task", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
        .alert("Create the folder?", isPresented: Binding(get: { approveFolder != nil }, set: { if !$0 { approveFolder = nil } })) {
            Button("Create and Start") {
                guard let pending = approveFolder else { return }
                spawn(pending.agent, machineId: pending.machineId, directory: pending.directory, approve: true)
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
                TaskAssigneePicker(assignee: task.assignee, agents: store.agentProfiles, openSessionId: openSessionId,
                                   worksInOpenSession: actions?.worksHere == true,
                                   offersOpenSession: actions?.offersThisSession == true)
                Picker("Status", selection: task.status) {
                    ForEach(AgentTask.Status.allCases) { Text($0.label).tag($0) }
                }
                if task.wrappedValue.assignee != .user {
                    TaskPermissionPicker(mode: task.permissionMode, agentId: permissionAgentId(task.wrappedValue))
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
                Text("Start Now starts the agent here; without a folder it uses the machine's latest folder. A scheduled start needs both.")
            }
            if let stored, let actions, stored.assignee != .user,
               actions.offersStartNow || actions.pendingStart != nil || actions.runningSessionId != nil {
                startSection(stored, actions)
            }
            sourceSection(task)
            TaskRepeatSections(task: task.wrappedValue, close: close)
            Section("Comment") {
                TextField("Add a comment", text: $comment, axis: .vertical)
                Button("Add Comment") {
                    let text = comment
                    comment = ""
                    Task {
                        if let saved = await store.updateTask(id: taskId, AgentTask.Update(comment: text)) {
                            // Keep any unsaved edits; the comment is already stored.
                            if changes == nil { draft = saved }
                            base = saved
                        }
                    }
                }
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Sessions") {
                let linked = task.wrappedValue.linkedSessions
                if linked.isEmpty {
                    Text("Not linked to any session yet.").foregroundStyle(.secondary)
                }
                ForEach(linked) { link in
                    Button {
                        Task { await store.openRelatedSession(link.sessionId) }
                        close()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.sessions[link.sessionId]?.title ?? link.sessionId).lineLimit(1)
                            Text(link.reasons.map(\.label).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

    /// The engine the task's permission names follow: its agent's, or its session's.
    private func permissionAgentId(_ task: AgentTask) -> String? {
        if let id = task.assignee.agentId { return store.agentProfile(id: id)?.providerId }
        return task.assignee.sessionId.flatMap { store.sessions[$0]?.agentId }
    }

    // MARK: Assign, start, schedule

    /// "Assign to…" item state: checked for who the task is for; choosing another only assigns it.
    private func assigned(_ assignee: AgentTask.Assignee) -> Binding<Bool> {
        Binding(get: {
            guard let current = stored?.assignee else { return false }
            if let id = assignee.agentId { return current.agentId == id }
            if let id = assignee.sessionId { return current.sessionId == id }
            return current == assignee
        }, set: { _ in assign(assignee) })
    }

    private func assign(_ assignee: AgentTask.Assignee) {
        guard let current = stored?.assignee else { return }
        if let id = assignee.agentId, current.agentId == id { return }
        if let id = assignee.sessionId, current.sessionId == id { return }
        AppHaptics.selection()
        working = true
        Task {
            await store.assignTask(id: taskId, to: assignee)
            working = false
        }
    }

    /// "Start Now", "Schedule…", the pending start with "Change…" and "Cancel", or where it runs:
    /// only what would change something is offered.
    private func startSection(_ task: AgentTask, _ actions: AgentTask.Actions) -> some View {
        Section {
            if actions.runsHere {
                Label("Running here", systemImage: "play.circle.fill")
                    .foregroundStyle(Color.userBubble)
            } else if let running = actions.runningSessionId {
                Button {
                    Task { await store.openRelatedSession(running) }
                    close()
                } label: {
                    LabeledContent("Running in", value: store.sessions[running]?.title ?? String(localized: "another session"))
                }
            }
            if let start = actions.pendingStart {
                LabeledContent("Starts", value: start.date.formatted(date: .abbreviated, time: .shortened))
                Button("Change…") { scheduling = ScheduleDraft(date: max(start.date, .now), isChange: true) }
                    .disabled(working)
                Button("Cancel Scheduled Start", role: .destructive) {
                    working = true
                    Task {
                        await store.cancelScheduledStart(id: taskId)
                        working = false
                    }
                }
                .disabled(working)
            }
            if actions.offersStartNow {
                Button("Start Now", systemImage: "play.fill") { startNow() }
                    .disabled(working || changes != nil)
            }
            if actions.offersSchedule {
                Button("Schedule…", systemImage: "calendar.badge.clock") {
                    if let problem = store.scheduleProblem(for: task) {
                        alert = problem
                    } else {
                        scheduling = ScheduleDraft(date: .now.addingTimeInterval(3600), isChange: false)
                    }
                }
                .disabled(working || changes != nil)
            }
        } header: {
            Text("Start")
        } footer: {
            if changes != nil {
                Text("Save your edits first.")
            } else if !actions.offersStartNow {
                EmptyView()
            } else if task.assignee.sessionId != nil {
                Text("Starting sends the task to \(store.taskAssigneeName(task.assignee)).")
            } else if task.scheduledStart == nil, let problem = store.scheduleProblem(for: task) {
                Text(problem).foregroundStyle(.orange)
            }
        }
    }

    private func startNow() {
        guard let task = stored else { return }
        if let sessionId = task.assignee.sessionId {
            guard store.sessions[sessionId] != nil else {
                alert = String(localized: "The task's session isn't on this device anymore. Assign the task again.")
                return
            }
            working = true
            Task {
                let sent = await store.startTaskInSession(id: taskId)
                working = false
                if sent {
                    await store.openRelatedSession(sessionId)
                    close()
                } else {
                    alert = String(localized: "The task couldn't be sent to its session. If the message failed there, retry it from the session.")
                }
            }
            return
        }
        guard let agent = task.assignee.agentId.flatMap({ store.agentProfile(id: $0) }) else {
            alert = String(localized: "This task's agent isn't on this device. Assign it again.")
            return
        }
        startAgent(agent)
    }

    /// Creates or moves the pending start; a new one for a Claude engine warns about automated access first.
    private func schedule(at date: Date, warned: Bool) {
        guard let task = stored else { return }
        if !warned, task.scheduledStart == nil,
           TaskRecurrence.needsAutomatedAccessWarning(providerId: store.scheduledStartProviderId(for: task)) {
            termsWarning = date
            return
        }
        working = true
        Task {
            await store.scheduleTaskStart(id: taskId, at: date)
            working = false
        }
    }

    /// The task's machine (or the first one online) and folder (or that machine's latest one).
    private func startAgent(_ agent: AgentProfile) {
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
        spawn(agent, machineId: machine.id, directory: directory, approve: false)
    }

    private func spawn(_ agent: AgentProfile, machineId: String, directory: String, approve: Bool) {
        working = true
        Task {
            let outcome = await store.startTaskNow(id: taskId, machineId: machineId, directory: directory, approveNewDirectory: approve)
            working = false
            draft = store.task(id: taskId)
            switch outcome {
            case .created: close()
            case .needsDirectoryApproval(let path): approveFolder = (agent, machineId, path)
            case .failed(let message): alert = message
            }
        }
    }
}

private struct ScheduleDraft: Identifiable {
    let date: Date
    let isChange: Bool
    var id: Date { date }
}

/// "Schedule…": the date and time the task starts, in this device's time zone, within a year.
private struct TaskScheduleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var date: Date
    let isChange: Bool
    let save: (Date) -> Void

    init(initial: Date, isChange: Bool, save: @escaping (Date) -> Void) {
        _date = State(initialValue: initial)
        self.isChange = isChange
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Starts", selection: $date, in: Date.now...TaskScheduledStart.latest(),
                               displayedComponents: [.date, .hourAndMinute])
                        #if os(iOS)
                        .datePickerStyle(.graphical)
                        #endif
                } footer: {
                    Text("Time zone: \(TimeZone.current.identifier). The task's machine starts it then, or when it wakes.")
                }
            }
            .formStyle(.grouped)
            .environment(\.timeZone, .current)
            .navigationTitle(isChange ? "Change Start" : "Schedule Start")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isChange ? "Save" : "Schedule") {
                        save(date)
                        dismiss()
                    }
                    .disabled(date <= .now)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
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
        // A change from elsewhere (e.g. an occurrence recorded) only replaces rules you haven't edited.
        .onChange(of: stored) { previous, latest in if !saving, draft == previous { draft = latest } }
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

extension AgentTask.SessionLink {
    /// How the session is linked to the task, as the task detail lists it.
    var label: String {
        switch self {
        case .assigned: String(localized: "Assigned to it")
        case .source: String(localized: "Where it came from")
        case .worked: String(localized: "Worked on it")
        case .occurrence: String(localized: "Ran a repeat")
        }
    }
}
