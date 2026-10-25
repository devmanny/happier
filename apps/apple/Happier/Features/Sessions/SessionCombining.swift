import HappierKit
import SwiftUI

/// A session row being dragged: its id as text behind a prefix, so only session rows take it (and
/// the conversation's drop-to-attach can tell it from a real file).
enum SessionDrag {
    static let prefix = "happier-session:"

    static func payload(_ sessionId: String) -> String { prefix + sessionId }

    static func sessionId(in text: String) -> String? {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : nil
    }

    /// A dropped "file" that is only a session row's drag text.
    static func isPayload(_ data: Data) -> Bool {
        String(decoding: data.prefix(prefix.utf8.count), as: UTF8.self) == prefix
    }
}

/// A session dropped on another one that holds no sessions yet.
struct SessionCombine: Identifiable {
    let dragged: Session
    let target: Session
    var id: String { "\(dragged.id)>\(target.id)" }
}

/// Asks what to do with two sessions dropped together: put one inside the other, or start a new
/// session holding both (named here, in the folder they share).
struct CombineSessions: ViewModifier {
    @Binding var request: SessionCombine?
    /// The session that now holds the dropped one, to unfold it.
    let onNested: (String) -> Void
    @Environment(HappierStore.self) private var store
    @State private var naming: SessionCombine?
    @State private var name = ""
    @State private var creating = false
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Combine Sessions", isPresented: present($request), titleVisibility: .visible, presenting: request) { combine in
                Button("Put Inside \u{201C}\(combine.target.title)\u{201D}") {
                    Task { await store.nest(combine.dragged.id, under: combine.target.id) }
                    onNested(combine.target.id)
                }
                Button("Group Both in a New Session") {
                    name = ""
                    naming = combine
                }
                Button("Cancel", role: .cancel) {}
            } message: { combine in
                Text("\u{201C}\(combine.dragged.title)\u{201D} was dropped on \u{201C}\(combine.target.title)\u{201D}.")
            }
            .alert("New Parent Session", isPresented: present($naming), presenting: naming) { combine in
                TextField("Name", text: $name)
                Button("Create") { group(combine) }
                Button("Cancel", role: .cancel) {}
            } message: { combine in
                Text("A new session that holds \u{201C}\(combine.target.title)\u{201D} and \u{201C}\(combine.dragged.title)\u{201D}, started in the folder they share.")
            }
            .alert("Couldn't Group the Sessions", isPresented: present($failure), presenting: failure) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            .overlay(alignment: .bottom) {
                if creating {
                    Label {
                        Text("Starting the parent session…")
                    } icon: {
                        HappierSpinner(size: HappierSpinner.mini)
                    }
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect()
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }

    private func group(_ combine: SessionCombine) {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = typed.isEmpty ? "\(combine.target.title) + \(combine.dragged.title)" : typed
        withAnimation(.smooth) { creating = true }
        Task {
            let outcome = await store.groupUnderNewSession(combine.dragged.id, combine.target.id, title: title)
            withAnimation(.smooth) { creating = false }
            switch outcome {
            case .created(let parentId): onNested(parentId)
            case .failed(let message): failure = message
            case .needsDirectoryApproval(let folder): failure = String(localized: "The folder \(folder) doesn't exist on that machine.")
            }
        }
    }

    private func present<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

/// Long press (or click) and drag a session row onto another. Applied where the row's context
/// menu is, so holding the row can turn into a drag.
struct SessionRowDrag: ViewModifier {
    let session: Session

    func body(content: Content) -> some View {
        content.draggable(SessionDrag.payload(session.id)) {
            // The drag preview is drawn outside the app's view tree, without its environment: only
            // views that need nothing from it (a full row reads the store and would crash).
            HStack(spacing: 10) {
                SessionAvatar(session: session, size: 26)
                Text(session.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 280, alignment: .leading)
            .background(.regularMaterial, in: Capsule())
        }
    }
}

/// "Move Into…": the sessions this one can go inside, to pick one (the same as dropping it there).
struct MoveIntoSheet: View {
    let session: Session
    let onPick: (Session) -> Void
    @Environment(HappierStore.self) private var store

    var body: some View {
        SessionPickerSheet(title: Text("Move \u{201C}\(session.title)\u{201D} Into"), offers: { target in
            target.id != session.id && target.id != session.parentSessionId && store.canNest(session.id, under: target.id)
        }, onPick: onPick)
    }
}
