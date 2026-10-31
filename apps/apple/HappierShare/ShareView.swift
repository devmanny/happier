import HappierKit
import SwiftUI
import UniformTypeIdentifiers

/// Picks the conversation and the message for what's being shared, then leaves both in the App
/// Group's outbox and opens Happier, which sends them through its normal send.
@MainActor @Observable
final class ShareModel {
    let targets = ShareTargets.load()?.items ?? []
    var selected: String?
    var message = ""
    var query = ""
    var sending = false
    var error: String?
    /// Names of what's being shared, as they're found.
    private(set) var fileCount: Int

    @ObservationIgnored private let context: NSExtensionContext?
    @ObservationIgnored private let openApp: (URL) -> Void
    @ObservationIgnored private var providers: [NSItemProvider]

    init(context: NSExtensionContext?, openApp: @escaping (URL) -> Void) {
        self.context = context
        self.openApp = openApp
        providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        fileCount = providers.count
    }

    var filtered: [ShareTargets.Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return targets }
        return targets.filter { $0.title.localizedCaseInsensitiveContains(q) || ($0.folder ?? "").localizedCaseInsensitiveContains(q) }
    }

    func cancel() {
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    func send() async {
        guard let sessionId = selected, let outbox = ShareOutbox.shared else { return }
        sending = true
        error = nil
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var files: [URL] = []
            for (index, provider) in providers.enumerated() {
                if let file = try await Self.copy(provider, into: folder.appendingPathComponent(String(index), isDirectory: true)) {
                    files.append(file)
                }
            }
            try outbox.add(sessionId: sessionId, message: message.trimmingCharacters(in: .whitespacesAndNewlines), files: files)
            openApp(URL(string: "happier-native://share")!)
            context?.completeRequest(returningItems: nil)
        } catch {
            self.error = String(localized: "The shared items couldn't be prepared: \(error.localizedDescription)")
            sending = false
        }
    }

    /// The shared item as a file, with its own name: a file URL as is, anything else (a photo,
    /// a memo) as the file representation it offers.
    private static func copy(_ provider: NSItemProvider, into folder: URL) async throws -> URL? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let preferred: [UTType] = [.image, .movie, .audio, .pdf, .data]
        guard let type = preferred.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { return nil }
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                // The file is gone once this returns: copy it now, under the name it was shared with.
                let base = suggested.map { ($0 as NSString).deletingPathExtension } ?? url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                let target = folder.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
                do {
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(model.fileCount == 1 ? "1 item" : "\(model.fileCount) items", systemImage: "paperclip")
                        .foregroundStyle(.secondary)
                    TextField("Add a message…", text: $model.message, axis: .vertical)
                        .lineLimit(1...5)
                }
                Section("Conversation") {
                    if model.targets.isEmpty {
                        Text("Open Happier once to see your conversations here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.filtered) { item in
                        Button {
                            model.selected = item.sessionId
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().fill(.fill.tertiary)
                                    if let agent = item.agentId {
                                        Image("Agents/\(agent)").resizable().scaledToFit().padding(6)
                                    }
                                }
                                .frame(width: 30, height: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).foregroundStyle(.primary).lineLimit(1)
                                    HStack(spacing: 4) {
                                        if let folder = item.folder { Text(folder) }
                                        Text("·")
                                        Text(item.date, style: .relative)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if model.selected == item.sessionId {
                                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let error = model.error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .searchable(text: $model.query, prompt: "Search conversations")
            .navigationTitle("Share to Happier")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.sending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await model.send() } }
                            .fontWeight(.semibold)
                            .disabled(model.selected == nil)
                    }
                }
            }
        }
    }
}
