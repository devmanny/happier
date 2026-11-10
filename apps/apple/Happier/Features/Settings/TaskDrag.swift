import HappierKit
import SwiftUI

extension View {
    /// A Tasks panel row that can be dragged onto an agent (its sidebar row or its open profile).
    func taskDrag(_ task: AgentTask) -> some View {
        draggable(AgentTask.dragPayload(id: task.id)) {
            // The drag preview is drawn outside the app's view tree, without its environment: only
            // views that need nothing from it.
            Label(task.title, systemImage: "checklist")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
    }

    /// Tasks dropped here are assigned to `agent` (`AgentTask.dropped(on:)`): only who they're
    /// for changes, their status stays and nothing starts. `targeted` is on while one is over it.
    func taskDrop(onto agent: AgentProfile, targeted: Binding<Bool>) -> some View {
        modifier(TaskDropTarget(agent: agent, targeted: targeted))
    }
}

private struct TaskDropTarget: ViewModifier {
    let agent: AgentProfile
    @Binding var targeted: Bool
    @Environment(HappierStore.self) private var store

    func body(content: Content) -> some View {
        content.dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(AgentTask.id(inDragPayload:)).filter { store.task(id: $0)?.dropped(on: agent) != nil }
            targeted = false
            guard !ids.isEmpty else { return false }
            AppHaptics.confirm()
            Task { await store.updateTasks(ids: ids, .assigning(.agent(agent))) }
            return true
        } isTargeted: { over in
            withAnimation(.smooth(duration: 0.15)) { targeted = over }
        }
    }
}
