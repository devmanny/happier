#if os(iOS)
import HappierKit
import SwiftUI
import UIKit

/// The iPhone layout, after the ChatGPT and Claude apps: the open conversation fills the screen and
/// the sessions are a sidebar that slides in from the left (the ≡ button, or dragging the conversation
/// to the right from anywhere), pushing the conversation aside. Tapping a session opens it and closes the sidebar; tapping
/// the conversation or swiping it back closes it too.
struct SessionDrawer: View {
    @Environment(HappierStore.self) private var store
    @Binding var selection: String?
    @Binding var isOpen: Bool
    /// Horizontal finger travel of a swipe in progress.
    @State private var dragX: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.84, 360)
            let offset = offset(width: width)
            let progress = offset / width
            ZStack(alignment: .topLeading) {
                NavigationStack {
                    DrawerSessionList(selected: selection, select: { selection = $0 }) { id in
                        selection = id
                        setOpen(false, feedback: false)
                    }
                    .equatable()
                }
                // Hidden under the conversation, the list keeps no animation running.
                .environment(\.sessionListOnScreen, isOpen || dragX != nil)
                .frame(width: width)
                // A little parallax: the sidebar travels slower than the conversation it reveals.
                .offset(x: (offset - width) * 0.3)
                .allowsHitTesting(isOpen && dragX == nil)
                .accessibilityHidden(!isOpen)
                .accessibilityAction(.escape) { setOpen(false) }

                NavigationStack {
                    conversation
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Sessions", systemImage: "line.3.horizontal") { setOpen(true) }
                            }
                        }
                }
                .accessibilityHidden(isOpen)
                // Opening turns the conversation into a grey card beside the sidebar (ChatGPT, Claude):
                // a mid grey veil lightens it on black and darkens it on white, and its corners round.
                .mask {
                    RoundedRectangle(cornerRadius: 44 * progress, style: .continuous)
                        .ignoresSafeArea()
                }
                // The card's own shadow on the sidebar: it follows the rounded corners (a straight
                // strip along the edge showed past them).
                .shadow(color: .black.opacity(0.2 * progress), radius: 14, x: -3)
                .overlay {
                    if offset > 0 {
                        RoundedRectangle(cornerRadius: 44 * progress, style: .continuous)
                            .fill(Color(white: 0.5).opacity(0.22 * progress))
                            .overlay(RoundedRectangle(cornerRadius: 44 * progress, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08 * progress), lineWidth: 1))
                            .contentShape(Rectangle())
                            .ignoresSafeArea()
                            .onTapGesture { setOpen(false) }
                            .gesture(closeSwipe(width: width))
                            .accessibilityElement()
                            .accessibilityLabel(Text("Close Sessions"))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { setOpen(false) }
                    }
                }
                .offset(x: offset)
                .gesture(OpenSwipe(enabled: !isOpen) { translation in
                    dragX = translation
                } onEnd: { translation, velocity in
                    settle(width: width, at: min(translation, width), velocity: velocity)
                })
            }
        }

    }

    @ViewBuilder
    private var conversation: some View {
        // Only membership: observing the session's contents rebuilt the navigation stack on each message.
        if selection == NewChat.id {
            NewSessionView()
        } else if let agentId = AgentProfile.id(inSelection: selection) {
            AgentProfileView(agentId: agentId)
                .id(agentId)
        } else if let selection, store.sessions.keys.contains(selection) {
            ChatView(sessionId: selection)
                .id(selection)
        } else if !store.hasLoadedSessions {
            // The last conversation reopens as soon as the list is known.
            HappierSpinner(size: HappierSpinner.hero)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Pick a session to see what your agent is up to.")
            } actions: {
                Button("Show Sessions") { setOpen(true) }
                    .buttonStyle(.glassProminent)
                    .glassHover()
            }
        }
    }

    /// Where the conversation sits: 0 closed, `width` open, following the finger in between.
    private func offset(width: CGFloat) -> CGFloat {
        let base = isOpen ? width : 0
        return min(max(base + (dragX ?? 0), 0), width)
    }

    /// Measured on the screen: in its own space the dragged layer moves under the finger, and the
    /// translation would chase its own offset and flicker.
    private func closeSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in dragX = min(value.translation.width, 0) }
            .onEnded { value in
                settle(width: width, at: width + min(value.translation.width, 0), velocity: value.velocity.width)
            }
    }

    /// Ends a swipe open or closed, by where the conversation (released at `position`) would coast to.
    private func settle(width: CGFloat, at position: CGFloat, velocity: CGFloat) {
        setOpen(position + velocity * 0.15 > width / 2)
    }

    private func setOpen(_ open: Bool, feedback: Bool = true) {
        if feedback, isOpen != open { AppHaptics.light() }
        // Opening the sidebar puts the keyboard away, like any other navigation: before the slide,
        // so the conversation isn't relaid out under the keyboard halfway through it.
        if open { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        withAnimation(.smooth(duration: 0.3)) {
            dragX = nil
            isOpen = open
        }
    }
}

/// Dragging the conversation to the right from anywhere. It only claims a drag that starts out
/// horizontal and rightward, so the transcript still scrolls vertically, and it leaves the drag to a
/// table that is scrolled sideways and can still scroll back.
private struct OpenSwipe: UIGestureRecognizerRepresentable {
    var enabled: Bool
    var onChange: (CGFloat) -> Void
    var onEnd: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        context.coordinator.enabled = enabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.enabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // In window coordinates: the conversation moves with the finger, so its own space would not.
        let space = recognizer.view?.window
        let translation = max(recognizer.translation(in: space).x, 0)
        switch recognizer.state {
        case .began, .changed:
            onChange(translation)
        case .ended, .cancelled, .failed:
            onEnd(translation, recognizer.velocity(in: space).x)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = true

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            guard velocity.x > 0, abs(velocity.x) > abs(velocity.y) * 1.2 else { return false }
            // A horizontally scrolled table under the finger scrolls back before the sidebar opens.
            var candidate = view.hitTest(pan.location(in: view), with: nil)
            while let current = candidate, current !== view {
                if let scroll = current as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1,
                   scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1 {
                    return false
                }
                candidate = current.superview
            }
            return true
        }
    }
}

/// The drawer's session list, rebuilt only when the selected session changes: not on the frame
/// the drawer starts sliding, nor on every frame of a swipe (its callbacks can't be compared, so
/// without this SwiftUI rebuilt the whole list each time).
private struct DrawerSessionList: View, Equatable {
    let selected: String?
    let select: (String?) -> Void
    let open: (String) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.selected == rhs.selected }

    var body: some View {
        SessionListView(selection: Binding(get: { selected }, set: { select($0) }), onOpen: open)
    }
}
#endif
