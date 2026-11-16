import Foundation
import notify

/// The dictation keyboard and the app talk through the App Group: an iOS keyboard can't use the
/// microphone (nor hold a Whisper model in its little memory), so the app listens and transcribes
/// and the keyboard types what it hears. Each side writes one small JSON file in the shared
/// container and wakes the other with a Darwin notification.
///
/// The app opened from the keyboard keeps the microphone on in the background for a while
/// (`standbyUntil`): taps on the keyboard's mic then start a take without leaving the app in use.
public enum DictationKeyboard {
    public static let appGroup = "group.com.devmanny.happier"
    /// The app, opened from the keyboard: starts the microphone (and the first take).
    public static let openURL = URL(string: "happier-native://keyboard-dictation")!

    /// Posted by the app whenever `Status` changes.
    public static let statusNotification = "com.devmanny.happier.keyboard.status"
    /// Posted by the keyboard after writing a `Command`.
    public static let commandNotification = "com.devmanny.happier.keyboard.command"

    /// What the app is doing for the keyboard.
    public struct Status: Codable, Equatable, Sendable {
        public enum Phase: String, Codable, Sendable {
            /// The microphone is off: the keyboard has to open the app to start.
            case off
            /// The microphone is on, waiting for a take.
            case ready
            /// The take is starting (permission, the microphone, the engine).
            case starting
            case recording
            /// No more audio; the last words are being transcribed.
            case finishing
        }

        public var phase: Phase
        /// Bumped by every take: the keyboard edits only the text of the take it's on.
        public var take: Int
        /// The take's whole text so far.
        public var text: String
        /// The take is over: `text` won't change any more.
        public var final: Bool
        /// The microphone stays on until then.
        public var standbyUntil: Date?
        /// Written every few seconds while the microphone is on: a status whose app was killed
        /// stops being fresh.
        public var heartbeat: Date
        public var error: String?
        /// The last command the app acted on.
        public var command: UUID?

        public init(phase: Phase = .off, take: Int = 0, text: String = "", final: Bool = false, standbyUntil: Date? = nil,
                    heartbeat: Date = .distantPast, error: String? = nil, command: UUID? = nil) {
            self.phase = phase
            self.take = take
            self.text = text
            self.final = final
            self.standbyUntil = standbyUntil
            self.heartbeat = heartbeat
            self.error = error
            self.command = command
        }

        /// How long a heartbeat counts.
        public static let heartbeatLifetime: TimeInterval = 45

        /// Whether the app is alive with the microphone on, so a take can start without opening it.
        public func microphoneOn(at now: Date = .now) -> Bool {
            guard phase != .off, let standbyUntil, standbyUntil > now else { return false }
            return now.timeIntervalSince(heartbeat) < Self.heartbeatLifetime
        }

        public var isListening: Bool { phase == .starting || phase == .recording || phase == .finishing }
    }

    /// What the keyboard asks.
    public struct Command: Codable, Equatable, Sendable {
        public enum Action: String, Codable, Sendable {
            case start
            /// Stop listening and type the last words.
            case finish
            /// Stop listening and drop the take's last words.
            case cancel
            /// Turn the microphone off now.
            case endStandby
        }

        public var id: UUID
        public var action: Action
        public var sent: Date

        public init(id: UUID = UUID(), action: Action, sent: Date = .now) {
            self.id = id
            self.action = action
            self.sent = sent
        }

        /// A command this old was meant for an app that wasn't listening then.
        public static let lifetime: TimeInterval = 10

        public func isFresh(at now: Date = .now) -> Bool { now.timeIntervalSince(sent) < Self.lifetime }
    }

    /// The shared container's files (nil when the App Group isn't reachable: a keyboard without
    /// Full Access).
    public struct Channel: Sendable {
        let directory: URL

        public init?(appGroup: String = DictationKeyboard.appGroup) {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
            self.init(directory: container.appending(path: "DictationKeyboard", directoryHint: .isDirectory))
        }

        public init(directory: URL) {
            self.directory = directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        private var statusFile: URL { directory.appending(path: "status.json") }
        private var commandFile: URL { directory.appending(path: "command.json") }

        public func readStatus() -> Status? { read(statusFile) }
        public func readCommand() -> Command? { read(commandFile) }

        /// Writes the status and wakes the keyboard.
        public func publish(_ status: Status) {
            write(status, to: statusFile)
            DictationKeyboard.post(DictationKeyboard.statusNotification)
        }

        /// Writes a command and wakes the app.
        public func send(_ command: Command) {
            write(command, to: commandFile)
            DictationKeyboard.post(DictationKeyboard.commandNotification)
        }

        private func read<T: Decodable>(_ file: URL) -> T? {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }

        private func write(_ value: some Encodable, to file: URL) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: Darwin notifications (they cross processes; they carry no data)

    public static func post(_ name: String) {
        notify_post(name)
    }

    /// Calls `handler` on the main queue whenever `name` is posted, until the returned observer is
    /// cancelled or released.
    public static func observe(_ name: String, _ handler: @escaping @MainActor @Sendable () -> Void) -> Observer {
        Observer(name: name, handler: handler)
    }

    public final class Observer: @unchecked Sendable {
        private var token: Int32 = NOTIFY_TOKEN_INVALID

        init(name: String, handler: @escaping @MainActor @Sendable () -> Void) {
            notify_register_dispatch(name, &token, .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
        }

        public func cancel() {
            guard token != NOTIFY_TOKEN_INVALID else { return }
            notify_cancel(token)
            token = NOTIFY_TOKEN_INVALID
        }

        deinit { cancel() }
    }
}

/// Keeps the text field in step with a take's text as it changes. Whisper revises its last words
/// while you speak, so each update deletes back to where the new text differs and types the rest.
/// Edits are computed here (testable); the keyboard applies them with the text document proxy.
/// Codable: a keyboard reloaded mid-take picks up where the last one was.
public struct KeyboardTextSync: Codable, Equatable, Sendable {
    public struct Edit: Equatable, Sendable {
        /// Characters to delete before the cursor.
        public var delete: Int
        public var insert: String

        public init(delete: Int, insert: String) {
            self.delete = delete
            self.insert = insert
        }

        public var isEmpty: Bool { delete == 0 && insert.isEmpty }
    }

    /// The take this text belongs to.
    public private(set) var take: Int?
    /// What this take has typed so far, the separator included.
    public private(set) var typed = ""
    /// The space put before the take's text, when it followed a word.
    private var separator: String?
    /// The text before the cursor stopped ending with what was typed (the cursor moved, or the
    /// user edited): nothing typed is taken back any more, new words are only added.
    public private(set) var appendOnly = false

    public init() {}

    /// The edit that brings the field to `text` of `take`. `before` is the text before the cursor
    /// as the field reports it (it may be cut short, or nil when the app doesn't say).
    public mutating func edit(take: Int, text: String, before: String?) -> Edit {
        if take != self.take {
            self.take = take
            typed = ""
            separator = nil
            appendOnly = false
        }
        if separator == nil, !text.isEmpty {
            separator = Self.needsSpace(before: before, text: text) ? " " : ""
        }
        let target = (separator ?? "") + text
        if !appendOnly, !Self.ends(before, with: typed) { appendOnly = true }
        if appendOnly {
            // Only what goes past what was typed already.
            guard target.count > typed.count else { return Edit(delete: 0, insert: "") }
            let added = String(target.dropFirst(typed.count))
            typed = target
            return Edit(delete: 0, insert: added)
        }
        let common = Self.commonPrefixCount(typed, target)
        let edit = Edit(delete: typed.count - common, insert: String(target.dropFirst(common)))
        typed = target
        return edit
    }

    /// The take is over: the next update belongs to a new one.
    public mutating func reset() {
        self = KeyboardTextSync()
    }

    /// Whether the field's text before the cursor still ends with `typed`. A field that reports
    /// nothing, or less than was typed, is trusted for the part it shows.
    static func ends(_ before: String?, with typed: String) -> Bool {
        guard let before, !typed.isEmpty else { return true }
        let shown = min(before.count, typed.count)
        return before.suffix(shown) == typed.suffix(shown)
    }

    static func needsSpace(before: String?, text: String) -> Bool {
        guard let last = before?.last, let first = text.first else { return false }
        if last.isWhitespace || last.isNewline { return false }
        // "hola" + ", qué tal": punctuation sticks to the word before it.
        if first.isPunctuation { return false }
        return true
    }

    static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            count += 1
        }
        return count
    }
}

/// Which takes the keyboard types, and how far it got in the one going on. Kept across keyboard
/// reloads (iOS makes a new keyboard for each app, and the app was opened in between to start the
/// microphone): every take from the first one the keyboard saw is typed once.
public struct KeyboardTyping: Codable, Equatable, Sendable {
    /// Takes up to this one are typed, or were over before the keyboard first looked.
    public private(set) var typedThrough: Int?
    public private(set) var sync = KeyboardTextSync()

    public init() {}

    /// The edit that types `status`'s take into the field; nil when the take isn't one to type.
    public mutating func edit(for status: DictationKeyboard.Status, before: String?) -> KeyboardTextSync.Edit? {
        guard let typedThrough else {
            self.typedThrough = status.final ? status.take : status.take - 1
            return status.final ? nil : edit(for: status, before: before)
        }
        guard status.take > typedThrough else { return nil }
        let edit = sync.edit(take: status.take, text: status.text, before: before)
        if status.final {
            self.typedThrough = status.take
            sync.reset()
        }
        return edit
    }
}
