import HappierKit
import SwiftUI

/// Files-style browser of a machine's folders (`daemon.filesystem.listRoots` / `listDirectory`),
/// with "New Folder" and a "Use this folder" action.
struct FolderBrowserView: View {
    let machine: Machine
    let recents: [String]
    let onSelect: (String) -> Void
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var stack: [RemoteFolder] = []
    @State private var roots: [RemoteFolder] = []
    @State private var rootsError: String?

    var body: some View {
        NavigationStack(path: $stack) {
            List {
                if !recents.isEmpty {
                    Section("Recents") {
                        ForEach(recents.prefix(8), id: \.self) { path in
                            NavigationLink(value: RemoteFolder(name: (path as NSString).lastPathComponent, path: path)) {
                                FolderRow(name: (path as NSString).lastPathComponent, detail: displayPath(path))
                            }
                        }
                    }
                }
                Section("Locations") {
                    if roots.isEmpty, rootsError == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if let rootsError {
                        Text(rootsError).foregroundStyle(.red)
                    }
                    ForEach(roots) { root in
                        NavigationLink(value: root) {
                            FolderRow(name: root.name, detail: root.name == root.path ? nil : displayPath(root.path), systemImage: "externaldrive")
                        }
                    }
                }
            }
            .navigationTitle(machine.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(for: RemoteFolder.self) { folder in
                FolderListView(machine: machine, folder: folder, stack: $stack) { path in
                    onSelect(path)
                    dismiss()
                }
            }
            .task {
                do { roots = try await store.folderRoots(on: machine.id) } catch {
                    rootsError = UserFacingError.message(for: error)
                }
            }
        }
    }

    private func displayPath(_ path: String) -> String {
        if let home = machine.homeDir, path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// One folder's subfolders. Pushes children onto the shared stack so a newly created folder can be opened.
private struct FolderListView: View {
    let machine: Machine
    let folder: RemoteFolder
    @Binding var stack: [RemoteFolder]
    let onUse: (String) -> Void
    @Environment(HappierStore.self) private var store
    @State private var folders: [RemoteFolder] = []
    @State private var truncated = false
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""
    @State private var showHidden = false
    @State private var naming = false
    @State private var newName = ""
    @State private var creating = false

    private var visible: [RemoteFolder] {
        folders.filter { (showHidden || !$0.isHidden) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        List {
            ForEach(visible) { child in
                NavigationLink(value: child) {
                    FolderRow(name: child.name, detail: nil)
                        .opacity(child.isHidden ? 0.6 : 1)
                }
            }
            if truncated {
                Text("Only the first folders are shown. Search to narrow it down.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if loading {
                ProgressView()
            } else if let error {
                ContentUnavailableView {
                    Label("Can't Open Folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if visible.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No Folders" : "No Results", systemImage: "folder",
                                       description: Text(query.isEmpty ? "Create one or use this folder." : "No folder matches “\(query)”."))
            }
        }
        .searchable(text: $query, prompt: "Search in \(folder.name)")
        .navigationTitle(folder.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newName = ""
                        naming = true
                    }
                    Toggle("Show Hidden Folders", systemImage: "eye", isOn: $showHidden)
                } label: {
                    Label("More", systemImage: creating ? "hourglass" : "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                onUse(folder.path)
            } label: {
                Text("Use “\(folder.name)”")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .alert("New Folder", isPresented: $naming) {
            TextField("Name", text: $newName)
                .autocorrectionDisabled()
            Button("Create") { Task { await create() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Inside \(folder.name)")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = folders.isEmpty
        error = nil
        do {
            let listing = try await store.folders(in: folder.path, on: machine.id)
            folders = listing.folders
            truncated = listing.truncated
        } catch {
            self.error = UserFacingError.message(for: error)
        }
        loading = false
    }

    /// Creates the folder, then opens it — like Files does.
    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else {
            store.lastError = String(localized: "Folder names can't be empty or contain slashes.")
            return
        }
        creating = true
        defer { creating = false }
        do {
            let created = try await store.createFolder(named: name, in: folder.path, on: machine.id)
            await load()
            stack.append(created)
        } catch {
            store.lastError = UserFacingError.message(for: error)
        }
    }
}

private struct FolderRow: View {
    let name: String
    let detail: String?
    var systemImage = "folder.fill"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.userBubble)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
