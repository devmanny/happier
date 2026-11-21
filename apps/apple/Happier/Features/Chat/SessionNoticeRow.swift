import HappierKit
import SwiftUI

/// Activity published by another session, kept apart from messages written by the user.
struct SessionActivityRow<Actions: View>: View {
    private enum Content {
        case notice(SessionNotice)
        case message(text: String, origin: SessionMessageOrigin)
    }

    private let content: Content
    let itemId: String
    let sessionId: String
    let date: Date
    let transportStatus: String?
    let transportStatusIsBlocked: Bool
    private let actions: Actions
    @Environment(HappierStore.self) private var store
    @State private var expanded = false
    @State private var showingOriginal = false
    @State private var copied = false
    @State private var openingSource = false

    init(notice: SessionNotice, itemId: String, sessionId: String, date: Date,
         transportStatus: String? = nil, transportStatusIsBlocked: Bool = false,
         @ViewBuilder actions: () -> Actions) {
        self.init(content: .notice(notice), itemId: itemId, sessionId: sessionId, date: date,
                  transportStatus: transportStatus, transportStatusIsBlocked: transportStatusIsBlocked, actions: actions)
    }

    init(messageText: String, origin: SessionMessageOrigin, itemId: String, sessionId: String, date: Date,
         transportStatus: String? = nil, transportStatusIsBlocked: Bool = false,
         @ViewBuilder actions: () -> Actions) {
        self.init(content: .message(text: messageText, origin: origin), itemId: itemId, sessionId: sessionId, date: date,
                  transportStatus: transportStatus, transportStatusIsBlocked: transportStatusIsBlocked, actions: actions)
    }

    private init(content: Content, itemId: String, sessionId: String, date: Date,
                 transportStatus: String?, transportStatusIsBlocked: Bool, @ViewBuilder actions: () -> Actions) {
        self.content = content
        self.itemId = itemId
        self.sessionId = sessionId
        self.date = date
        self.transportStatus = transportStatus
        self.transportStatusIsBlocked = transportStatusIsBlocked
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
                header
                if case .message(_, let origin) = content {
                    sourceButton(origin)
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    expandedContent
                    actions
                    DisclosureGroup(isExpanded: Binding(get: { showingOriginal }, set: { next in
                        if next != showingOriginal { AppHaptics.light() }
                        showingOriginal = next
                    })) {
                        deliveryDetails
                    } label: {
                        Text(isMessage ? String(localized: "Delivery details and identifiers") : String(localized: "Original text and identifiers"))
                            .font(.caption2)
                            .frame(minHeight: 44, alignment: .leading)
                            .accessibilityIdentifier("\(prefix)-original-\(itemId)")
                    }
                }
                .padding(.leading, 30)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private var header: some View {
        Button {
            AppHaptics.light()
            expanded.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .frame(width: 20, height: 20)
                    .overlay(alignment: .bottomTrailing) {
                        if let iconBadge {
                            Image(systemName: iconBadge)
                                .font(.system(size: 8, weight: .semibold))
                                .padding(1)
                                .background(.background, in: Circle())
                                .offset(x: 4, y: 3)
                        }
                    }
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(isMessage ? 1 : nil)
                    Text(metadata)
                        .font(.caption2)
                        .foregroundStyle(transportStatusIsBlocked ? Color.orange : Color.secondary)
                        .lineLimit(isMessage ? 1 : nil)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("\(prefix)-\(itemId)")
        .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityHint(expanded ? Text("Hides activity details") : Text("Shows activity details"))
    }

    private func sourceButton(_ origin: SessionMessageOrigin) -> some View {
        Button {
            AppHaptics.light()
            openingSource = true
            Task {
                await store.openRelatedSession(origin.senderSessionId)
                openingSource = false
            }
        } label: {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 16))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(openingSource)
        .accessibilityLabel("Open Sender Session")
        .accessibilityValue(Text(openingSource ? String(localized: "Opening") : senderTitle(origin)))
        .accessibilityIdentifier("session-message-source-\(itemId)")
    }

    @ViewBuilder private var expandedContent: some View {
        switch content {
        case .notice(let notice):
            if let detail = notice.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let relatedId = notice.relatedSessionId, relatedId != sessionId,
               let related = store.sessions[relatedId] {
                Button {
                    AppHaptics.light()
                    store.openRequest = relatedId
                } label: {
                    Label("View Session", systemImage: "arrow.up.right")
                        .font(.caption)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .accessibilityValue(Text(related.title))
                .accessibilityIdentifier("session-notice-related-\(itemId)")
            }
        case .message(let text, let origin):
            HStack(alignment: .top) {
                Text("\(senderTitle(origin)) → \(targetTitle(origin))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("From \(senderTitle(origin)) to \(targetTitle(origin))")
                Spacer(minLength: 8)
                copyButton
            }
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("session-message-text-\(itemId)")
        }
    }

    @ViewBuilder private var deliveryDetails: some View {
        switch content {
        case .notice(let notice):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Original Text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    copyButton
                }
                Text(notice.originalText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                identifier("Session ID", value: sessionId)
                if let relatedId = notice.relatedSessionId {
                    identifier("Related Session ID", value: relatedId)
                }
            }
        case .message(_, let origin):
            VStack(alignment: .leading, spacing: 8) {
                identifier("From Session ID", value: origin.senderSessionId)
                identifier("To Session ID", value: origin.targetSessionId)
                identifier("Time", value: date.formatted(date: .abbreviated, time: .standard))
                if let transportStatus {
                    identifier("Transport Status", value: transportStatus)
                }
            }
        }
    }

    private var copyButton: some View {
        Button {
            MessageClipboard.copy(originalText)
            AppHaptics.success()
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.callout)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(isMessage ? String(localized: "Copy Message") : String(localized: "Copy Original Text")))
        .accessibilityValue(copied ? Text("Copied") : Text(""))
        .accessibilityIdentifier("\(prefix)-copy-\(itemId)")
    }

    private func identifier(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var isMessage: Bool {
        if case .message = content { true } else { false }
    }

    private var prefix: String { isMessage ? "session-message" : "session-notice" }

    private var originalText: String {
        switch content {
        case .notice(let notice): notice.originalText
        case .message(let text, _): text
        }
    }

    private func senderTitle(_ origin: SessionMessageOrigin) -> String {
        store.sessions[origin.senderSessionId]?.title ?? String(localized: "Another session")
    }

    private func targetTitle(_ origin: SessionMessageOrigin) -> String {
        store.sessions[origin.targetSessionId]?.title
            ?? (origin.targetSessionId == sessionId ? String(localized: "This session") : String(localized: "Another session"))
    }

    private var headline: String {
        switch content {
        case .message(_, let origin): senderTitle(origin)
        case .notice(let notice): noticeHeadline(notice)
        }
    }

    private func noticeHeadline(_ notice: SessionNotice) -> String {
        let relatedTitle = notice.relatedSessionTitle ?? notice.relatedSessionId.flatMap { store.sessions[$0]?.title }
        let subject = relatedTitle.map { "“\($0)”" } ?? String(localized: "Subagent")
        switch notice.kind {
        case .parentLinked:
            return relatedTitle.map { String(localized: "Linked to “\($0)”") } ?? String(localized: "Linked to parent session")
        case .parentDetached: return String(localized: "Detached from parent session")
        case .childAdopted: return String(localized: "\(subject) linked to this session")
        case .childReleased: return String(localized: "\(subject) detached from this session")
        case .turnCompleted: return String(localized: "\(subject) finished its turn")
        case .turnFailed: return String(localized: "\(subject) failed")
        case .blockedPermission: return String(localized: "\(subject) needs permission")
        case .blockedQuestion: return String(localized: "\(subject) is waiting for an answer")
        case .stopped: return String(localized: "\(subject) stopped")
        }
    }

    private var metadata: String {
        [isMessage ? String(localized: "Message") : String(localized: "Automatic notice"),
         transportStatus, date.formatted(date: .omitted, time: .shortened)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var symbol: String {
        switch content {
        case .message: return "bubble.left.and.bubble.right"
        case .notice(let notice):
            return switch notice.kind {
            case .parentLinked, .parentDetached, .childAdopted, .childReleased: "link"
            case .turnCompleted: "checkmark.circle"
            case .turnFailed: "exclamationmark.circle"
            case .blockedPermission: "hand.raised"
            case .blockedQuestion: "questionmark.circle"
            case .stopped: "stop.circle"
            }
        }
    }

    private var iconBadge: String? {
        guard case .notice(let notice) = content else { return nil }
        return switch notice.kind {
        case .parentLinked: "arrow.up"
        case .childAdopted: "arrow.down"
        case .parentDetached, .childReleased: "minus"
        default: nil
        }
    }

    private var iconColor: Color {
        switch content {
        case .message: return .secondary
        case .notice(let notice):
            return switch notice.kind {
            case .turnCompleted: .green
            case .turnFailed: .red
            case .blockedPermission, .blockedQuestion: .orange
            default: .secondary
            }
        }
    }
}

extension SessionActivityRow where Actions == EmptyView {
    init(notice: SessionNotice, itemId: String, sessionId: String, date: Date,
         transportStatus: String? = nil, transportStatusIsBlocked: Bool = false) {
        self.init(notice: notice, itemId: itemId, sessionId: sessionId, date: date,
                  transportStatus: transportStatus, transportStatusIsBlocked: transportStatusIsBlocked) { EmptyView() }
    }

    init(messageText: String, origin: SessionMessageOrigin, itemId: String, sessionId: String, date: Date,
         transportStatus: String? = nil, transportStatusIsBlocked: Bool = false) {
        self.init(messageText: messageText, origin: origin, itemId: itemId, sessionId: sessionId, date: date,
                  transportStatus: transportStatus, transportStatusIsBlocked: transportStatusIsBlocked) { EmptyView() }
    }
}
