import HappierKit
import os
import SwiftUI
import UIKit

private let log = Logger(subsystem: "dev.happier.apple", category: "keyboard")

/// The dictation keyboard: a microphone button, the words appearing in the text field as they're
/// heard, and the keys you still need (globe, space, delete, return). The app does the listening
/// (`DictationKeyboard`); this types what it publishes.
final class KeyboardViewController: UIInputViewController {
    private lazy var model = KeyboardModel(controller: self)

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        // The keyboard's height: required-but-one, so the system's own constraints win while it
        // animates in, and the view sizes itself rather than taking the system keyboard's height.
        (view as? UIInputView)?.allowsSelfSizing = true
        let height = view.heightAnchor.constraint(equalToConstant: 216)
        height.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.appeared()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.disappeared()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        model.fieldChanged()
    }

    /// Opens the app. A keyboard has no `UIApplication.shared`; the app object is reached through
    /// the responder chain, as every keyboard that opens its app does.
    func openApp(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias Open = @convention(c) (NSObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                log.notice("opened the app")
                return
            }
            responder = current.next
        }
        log.error("couldn't open the app: no application in the responder chain")
    }
}

/// The keyboard's state: the app's last status, and typing its takes into the field.
@MainActor
@Observable
final class KeyboardModel {
    private(set) var status: DictationKeyboard.Status?
    private(set) var hasFullAccess = false
    /// No system globe below the keyboard (Home-button iPhones, some iPads): the keyboard shows one.
    private(set) var needsGlobe = false
    /// The field's return key, as the app asked for it.
    private(set) var returnTitle = String(localized: "return")
    /// Waiting for the app to answer a command (or to come up after being opened).
    private(set) var waiting = false
    /// The space bar is held: the keyboard is a trackpad for the cursor.
    private(set) var trackpad = false

    /// Weak: the SwiftUI view keeps the model, and a status notification can still arrive after
    /// the system let go of the keyboard; there's no field to type in then.
    @ObservationIgnored private weak var controller: KeyboardViewController?
    @ObservationIgnored private var channel: DictationKeyboard.Channel?
    @ObservationIgnored private var observer: DictationKeyboard.Observer?
    @ObservationIgnored private var typing = KeyboardTyping()
    @ObservationIgnored private var fallback: Task<Void, Never>?
    private static let typingKey = "keyboard.typing"

    init(controller: KeyboardViewController) {
        self.controller = controller
    }

    var listening: Bool { status?.isListening ?? false }
    var microphoneOn: Bool { status?.microphoneOn() ?? false }

    func appeared() {
        guard let controller else { return }
        hasFullAccess = controller.hasFullAccess
        needsGlobe = controller.needsInputModeSwitchKey
        fieldChanged()
        guard hasFullAccess else { return }
        if channel == nil { channel = DictationKeyboard.Channel() }
        if let data = UserDefaults.standard.data(forKey: Self.typingKey),
           let saved = try? JSONDecoder().decode(KeyboardTyping.self, from: data) {
            typing = saved
        }
        observer = DictationKeyboard.observe(DictationKeyboard.statusNotification) { [weak self] in
            self?.statusChanged()
        }
        statusChanged()
    }

    func disappeared() {
        observer = nil
        fallback?.cancel()
        waiting = false
    }

    func fieldChanged() {
        guard let proxy else { return }
        let title: String = switch proxy.returnKeyType {
        case .go: String(localized: "go")
        case .search, .google, .yahoo: String(localized: "search")
        case .send: String(localized: "send")
        case .done: String(localized: "done")
        case .next: String(localized: "next")
        case .join: String(localized: "join")
        default: String(localized: "return")
        }
        if title != returnTitle { returnTitle = title }
    }

    // MARK: Keys

    func micTapped() {
        guard hasFullAccess, let channel else {
            log.notice("mic tapped without Full Access")
            return
        }
        let current = channel.readStatus()
        log.notice("mic tapped: app \(current.map { "\($0.phase.rawValue) on=\($0.microphoneOn())" } ?? "silent", privacy: .public)")
        if current?.isListening == true {
            send(.finish)
        } else if current?.microphoneOn() == true {
            send(.start)
            // No answer (the app was killed since its last heartbeat): open it instead.
            let sent = current?.take
            fallback?.cancel()
            fallback = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, !Task.isCancelled, self.status?.take == sent, !self.listening else { return }
                self.open()
            }
        } else {
            open()
        }
    }

    func turnMicrophoneOff() {
        send(.endStandby)
    }

    func space() { proxy?.insertText(" ") }
    func newline() { proxy?.insertText("\n") }
    func deleteBackward() { proxy?.deleteBackward() }

    var globeTarget: UIInputViewController? { controller }

    private var proxy: (any UITextDocumentProxy)? { controller?.textDocumentProxy }

    // MARK: Trackpad

    @ObservationIgnored private lazy var tick = UISelectionFeedbackGenerator()

    func trackpadBegan() {
        trackpad = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        tick.prepare()
    }

    func trackpadEnded() { trackpad = false }

    func moveCursor(by characters: Int) {
        proxy?.adjustTextPosition(byCharacterOffset: characters)
        tick.selectionChanged()
    }

    func moveLine(_ direction: KeyboardCursor.Direction) {
        guard let proxy else { return }
        let offset = KeyboardCursor.lineOffset(
            direction,
            before: proxy.documentContextBeforeInput ?? "",
            after: proxy.documentContextAfterInput ?? "",
            lineLength: lineLength
        )
        guard offset != 0 else { return }
        proxy.adjustTextPosition(byCharacterOffset: offset)
        tick.selectionChanged()
    }

    /// About how many characters fit on a line of the field: the keyboard can't see the field's
    /// layout, so this assumes it spans the screen, less its margins, in the 17-point system font.
    private var lineLength: Int {
        let width = (controller?.view.bounds.width ?? 390) - 40
        return max(Int(width / 8.4), 12)
    }

    // MARK: The app

    private func open() {
        waiting = true
        controller?.openApp(DictationKeyboard.openURL)
    }

    private func send(_ action: DictationKeyboard.Command.Action) {
        waiting = action == .start || action == .finish
        channel?.send(DictationKeyboard.Command(action: action))
    }

    private func statusChanged() {
        guard let status = channel?.readStatus() else { return }
        if status != self.status { self.status = status }
        if status.isListening || status.final || status.phase == .off { waiting = false }
        typeTake(status)
    }

    private func typeTake(_ status: DictationKeyboard.Status) {
        guard let proxy else { return }
        guard let edit = typing.edit(for: status, before: proxy.documentContextBeforeInput) else { return }
        if !edit.isEmpty {
            for _ in 0..<edit.delete { proxy.deleteBackward() }
            if !edit.insert.isEmpty { proxy.insertText(edit.insert) }
        }
        if let data = try? JSONEncoder().encode(typing) {
            UserDefaults.standard.set(data, forKey: Self.typingKey)
        }
    }
}
