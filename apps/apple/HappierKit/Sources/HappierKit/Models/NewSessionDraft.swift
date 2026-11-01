import Foundation

/// The location carried into the normal new-session assistant. Creating this draft has no
/// session side effects, so cancelling leaves the existing conversations untouched.
public struct NewSessionDraft: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let machineId: String
    public let directory: String
    public let group: NewSessionGroup?

    public init?(inFolderOf session: Session) {
        guard let machineId = session.machineId, !machineId.isEmpty,
              let directory = session.path, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.machineId = machineId
        self.directory = directory
        group = nil
    }

    public init?(grouping dragged: Session, with target: Session) {
        guard let location = NewSessionDraft(inFolderOf: target) else { return nil }
        machineId = location.machineId
        if dragged.machineId == machineId, let otherPath = dragged.path,
           let shared = SessionTree.sharedFolder(location.directory, otherPath) {
            directory = shared
        } else {
            directory = location.directory
        }
        group = NewSessionGroup(draggedId: dragged.id, targetId: target.id,
                                suggestedTitle: "\(target.title) + \(dragged.title)")
    }
}

/// Applied only after the assistant successfully starts its new parent session.
public struct NewSessionGroup: Equatable, Sendable {
    public let draggedId: String
    public let targetId: String
    public let suggestedTitle: String
}
