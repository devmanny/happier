import HappierKit
import SwiftUI

/// "Put Sessions to Rest": every running session of the user's with what it's doing right now,
/// all chosen to begin with; the user unchecks the ones to keep running. Each one put to rest
/// stops on its computer, shows as Resting and wakes with Wake Session.
struct RestSessionsSheet: View {
    let request: SessionRest.Candidates
    @Environment(HappierStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String>

    init(request: SessionRest.Candidates) {
        self.request = request
        _chosen = State(initialValue: Set(request.all))
    }

    var body: some View {
        // Live: a session that starts or finishes a turn while this is open shows it.
        let activities = store.restActivities
        let toRest = request.all.filter { chosen.contains($0) && activities[$0] != nil }
        let interrupting = toRest.filter { activities[$0]?.isBusy == true }.count
        NavigationStack {
            // The busy ones first, as they were when this opened; each row's status is live. One
            // archived or deleted meanwhile (on another device) leaves the list.
            List(request.busy + request.idle, id: \.self) { id in
                if store.sessions[id] != nil { row(id, activity: activities[id]) }
            }
            .navigationTitle("Put Sessions to Rest")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if chosen.isSuperset(of: request.all) {
                        Button("Deselect All") { chosen = [] }
                    } else {
                        Button("Select All") { chosen = Set(request.all) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Group {
                        if interrupting > 0 {
                            Text("^[\(interrupting) of them](inflect: true) will be interrupted. Each conversation stays and wakes when you need it.")
                        } else {
                            Text("Their agents stop on their computers. Each conversation stays and wakes when you need it.")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    Button {
                        if interrupting > 0 { AppHaptics.warning() } else { AppHaptics.confirm() }
                        dismiss()
                        Task { await store.confirmRest(toRest) }
                    } label: {
                        Text("Put ^[\(toRest.count) Session](inflect: true) to Rest")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(toRest.isEmpty)
                    .accessibilityIdentifier("rest-sessions-confirm")
                }
                .padding()
                .background(.bar)
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 540)
        #endif
    }

    private func row(_ id: String, activity: SessionRest.Activity?) -> some View {
        let isChosen = chosen.contains(id) && activity != nil
        let session = store.sessions[id]
        return Button {
            AppHaptics.selection()
            if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session?.title ?? "")
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if let folder = session?.folderName {
                        Text(folder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                ActivityLabel(activity: activity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(activity == nil)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("rest-session-\(id)")
    }
}

/// What a running session is doing, in a word or two.
private struct ActivityLabel: View {
    let activity: SessionRest.Activity?

    var body: some View {
        text
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private var text: Text {
        switch activity {
        case nil: Text("Stopped")
        case .idle: Text("Idle")
        case .working: Text("Working")
        case .waitingForYou: Text("Waiting for you")
        case .queued(let count): Text("^[\(count) message](inflect: true) queued")
        case .sending: Text("Sending a message")
        case .backgroundWork: Text("Background work")
        case .subSessionWorking: Text("Sub-session working")
        case .atTerminal: Text("In use at the terminal")
        }
    }

    private var color: Color {
        switch activity {
        case nil, .idle: .secondary
        case .waitingForYou: .orange
        default: .blue
        }
    }
}
