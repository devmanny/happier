import HappierKit
import SwiftUI

extension View {
    /// "Start Now" wherever a task shows (its detail, its agent's profile): setting `request` to a
    /// task id starts it with `HappierStore.startTask`, asks before creating a missing folder, and
    /// says why when it couldn't start. `started` gets the session the task now runs in.
    func taskStart(_ request: Binding<String?>, working: Binding<Bool>,
                   started: @escaping @MainActor (String) async -> Void) -> some View {
        modifier(TaskStartFlow(request: request, working: working, started: started))
    }
}

private struct TaskStartFlow: ViewModifier {
    @Binding var request: String?
    @Binding var working: Bool
    let started: @MainActor (String) async -> Void
    @Environment(HappierStore.self) private var store
    @State private var problem: String?
    @State private var folder: FolderQuestion?

    private struct FolderQuestion {
        let taskId: String
        let machineId: String
        let directory: String
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, taskId in
                guard let taskId else { return }
                request = nil
                start(taskId, approvedFolder: nil)
            }
            .alert("Task", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            .alert("Create the folder?", isPresented: Binding(get: { folder != nil }, set: { if !$0 { folder = nil } })) {
                Button("Create and Start") {
                    guard let pending = folder else { return }
                    start(pending.taskId, approvedFolder: (pending.machineId, pending.directory))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(folder?.directory ?? "")
            }
    }

    private func start(_ taskId: String, approvedFolder: (machineId: String, directory: String)?) {
        working = true
        Task {
            let outcome = await store.startTask(id: taskId, approvedFolder: approvedFolder)
            working = false
            switch outcome {
            case .started(let sessionId): await started(sessionId)
            case .needsFolderApproval(let machineId, let directory):
                folder = FolderQuestion(taskId: taskId, machineId: machineId, directory: directory)
            case .failed(let message): problem = message
            }
        }
    }
}
