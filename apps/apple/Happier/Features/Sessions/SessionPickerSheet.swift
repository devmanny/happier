import HappierKit
import SwiftUI

/// The one sheet for picking a session out of a list ("Send to Session…", "Move Into…"): the same
/// rows as the sidebar, a search, and Cancel. The caller says which sessions are on offer.
struct SessionPickerSheet: View {
    let title: Text
    /// Whether a session is one to offer.
    let offers: (Session) -> Bool
    let onPick: (Session) -> Void
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [Session] {
        store.sessionList.filter { offers($0) && (query.isEmpty || $0.matches(query)) }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { session in
                Button {
                    dismiss()
                    onPick(session)
                } label: {
                    SessionRow(session: session)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            #if os(iOS)
            .listStyle(.plain)
            #endif
            .searchable(text: $query, prompt: "Search Sessions")
            .overlay {
                if candidates.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}
