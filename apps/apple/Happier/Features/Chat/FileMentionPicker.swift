import HappierKit
import SwiftUI

/// Picks a file of the session's project to mention (`@path`): browse its folders, or search its
/// files and folders by name. Paths come back relative to the session's folder, as the agent sees them.
struct FileMentionPicker: View {
    let machineId: String
    let root: String
    let onPick: (String) -> Void
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var stack: [RemoteEntry] = []
    @State private var query = ""
    @State private var results: FileSuggestionResults = .loading

    var body: some View {
        NavigationStack(path: $stack) {
            FileMentionFolder(machineId: machineId, path: root, root: root, pick: pick)
                .navigationTitle("Mention a File")
                .navigationDestination(for: RemoteEntry.self) { folder in
                    FileMentionFolder(machineId: machineId, path: folder.path, root: root, pick: pick)
                        .navigationTitle(folder.name)
                }
                .overlay {
                    if !query.isEmpty { searchResults }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                }
        }
        .searchable(text: $query, prompt: "Search Files")
        .task(id: query) {
            guard !query.isEmpty else {
                results = .loading
                return
            }
            results = await FileSuggestionResults.load(query, in: root, on: machineId, limit: 100, store: store) ?? results
        }
    }

    @ViewBuilder private var searchResults: some View {
        switch results {
        case .found(let hits) where hits.isEmpty:
            ContentUnavailableView.search(text: query)
                .background(.background)
        case .found(let hits):
            List(hits, id: \.self) { path in
                let label = FileSuggestionResults.label(path)
                Button { pick(path) } label: {
                    FileMentionRow(name: label.name, detail: label.folder, isDirectory: label.isFolder)
                }
                .buttonStyle(.plain)
            }
            #if os(iOS)
            .listStyle(.plain)
            #endif
        case .failed(let message):
            ContentUnavailableView("Can't Search", systemImage: "exclamationmark.magnifyingglass", description: Text(message))
                .background(.background)
        case .loading:
            HappierSpinner(size: HappierSpinner.hero)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        }
    }

    private func pick(_ relativePath: String) {
        onPick(relativePath)
        dismiss()
    }
}

/// One folder of the project: its folders open, its files are picked.
private struct FileMentionFolder: View {
    let machineId: String
    let path: String
    let root: String
    let pick: (String) -> Void
    @Environment(HappierStore.self) private var store
    @State private var entries: [RemoteEntry]?
    @State private var error: String?

    var body: some View {
        Group {
            if let entries {
                List(entries) { entry in
                    if entry.isDirectory {
                        NavigationLink(value: entry) {
                            FileMentionRow(name: entry.name, detail: nil, isDirectory: true)
                        }
                    } else {
                        Button { pick(relative(entry.path)) } label: {
                            FileMentionRow(name: entry.name, detail: nil, isDirectory: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                #if os(iOS)
                .listStyle(.plain)
                #endif
                .overlay {
                    if entries.isEmpty {
                        ContentUnavailableView("Empty Folder", systemImage: "folder")
                    }
                }
            } else if let error {
                ContentUnavailableView("Can't Open Folder", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                HappierSpinner(size: HappierSpinner.hero)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard entries == nil else { return }
            do {
                entries = try await store.entries(in: path, on: machineId)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The path as the agent sees it from the session's folder.
    private func relative(_ absolute: String) -> String {
        for separator in ["/", "\\"] where absolute.hasPrefix(root + separator) {
            return String(absolute.dropFirst(root.count + 1))
        }
        return absolute
    }
}

private struct FileMentionRow: View {
    let name: String
    let detail: String?
    let isDirectory: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(isDirectory ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
