import Foundation

/// The messages being read aloud, in order: the one reading now, what's waiting after it, and
/// what was already read (so the player can go a whole message back). A message that arrives
/// mid-reading waits its turn instead of cutting in.
public struct ReadAloudQueue: Equatable, Sendable {
    /// One message: what the player calls a block.
    public struct Block: Equatable, Sendable {
        public let id: String
        public let text: String

        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    private var blocks: [Block] = []
    /// The block being read; nil when idle (everything read, or nothing yet).
    private var index: Int?
    /// The block read last, for "back" once idle.
    private var lastIndex: Int?

    public init() {}

    public var current: Block? { index.map { blocks[$0] } }
    /// Blocks waiting after the current one.
    public var waiting: Int { index.map { blocks.count - $0 - 1 } ?? 0 }
    public var hasNext: Bool { waiting > 0 }
    public var hasPrevious: Bool {
        if let index { return index > 0 }
        return lastIndex != nil
    }

    /// Reads `block` now, alone: picking a message by hand replaces the queue.
    public mutating func play(_ block: Block) {
        blocks = [block]
        index = 0
        lastIndex = nil
    }

    /// Adds `block` after the others (once per message); returns it when nothing was being read,
    /// so it should start now.
    public mutating func enqueue(_ block: Block) -> Block? {
        guard !blocks.contains(where: { $0.id == block.id }) else { return nil }
        blocks.append(block)
        guard index == nil else { return nil }
        index = blocks.count - 1
        return block
    }

    /// The current block finished (or "next"): the following one, or nil when there's none.
    public mutating func advance() -> Block? {
        guard let current = index else { return nil }
        lastIndex = current
        guard current + 1 < blocks.count else {
            index = nil
            return nil
        }
        index = current + 1
        return blocks[current + 1]
    }

    /// The block before the current one (or the last one read, once idle).
    public mutating func previous() -> Block? {
        let target: Int? = if let index { index > 0 ? index - 1 : nil } else { lastIndex }
        guard let target else { return nil }
        index = target
        return blocks[target]
    }

    public mutating func clear() {
        self = ReadAloudQueue()
    }

    public enum Growth: Equatable, Sendable {
        /// The message is being read now: read `added` after what's left of it.
        case appendToCurrent(String)
        /// It was still waiting; it now waits with all of its text.
        case updated
        /// It was read already: the new part waits its turn as a block of its own.
        case queued
        /// Nothing was being read: start this block now.
        case started(Block)
    }

    /// More of a streamed message arrived (`added`, the part after what was taken before).
    public mutating func grow(id messageId: String, text: String, added: String) -> Growth {
        let latest = blocks.lastIndex { $0.id == messageId || $0.id.hasPrefix(messageId + "#") }
        if let latest, let index, latest >= index {
            blocks[latest] = Block(id: blocks[latest].id, text: blocks[latest].text + " " + added)
            return latest == index ? .appendToCurrent(added) : .updated
        }
        let more = Block(id: "\(messageId)#\(blocks.count)", text: added)
        if let now = enqueue(more) { return .started(now) }
        return .queued
    }
}

/// Which agent messages auto read takes from a conversation: those that arrive after it's turned
/// on, once complete (something came after them, or the turn is over), and never the thinking.
public struct AutoReadCursor: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case new(ReadAloudQueue.Block)
        /// A message already taken grew (it streams in): `added` is the part not read yet.
        case grew(id: String, added: String, text: String)
    }

    /// Already in the conversation when auto read was turned on: never read.
    private var skipped: Set<String>
    /// The text of each message taken so far.
    private var taken: [String: String] = [:]
    /// Each agent message's text as last seen, untrimmed: one that hasn't changed is passed over
    /// without being looked at again (a conversation changes on every streamed piece).
    private var seen: [String: String] = [:]
    /// Messages whose text was looked at (trimmed and compared), for tests.
    public private(set) var examinedCount = 0

    public init(existing items: [ChatItem]) {
        skipped = Set(items.map(\.id))
    }

    public mutating func take(_ items: [ChatItem], turnActive: Bool, recording: Bool = false) -> [Change] {
        // Speaking to the agent interrupts the old reply, including text still streaming or
        // arriving during microphone use. Remember identities across transcript window changes.
        if recording {
            skipped.formUnion(items.map(\.id))
            return []
        }
        var changes: [Change] = []
        for (offset, item) in items.enumerated() {
            guard case .agentText(let message) = item, !message.isThinking, !skipped.contains(message.id) else { continue }
            // The last item of a running turn may still be growing.
            guard !turnActive || offset < items.count - 1 else { continue }
            guard seen[message.id] != message.text else { continue }
            seen[message.id] = message.text
            examinedCount += 1
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let before = taken[message.id] {
                guard text != before else { continue }
                taken[message.id] = text
                // A rewrite rather than more text isn't read again. Compared and cut by bytes:
                // character by character this walked the whole reply on every streamed piece.
                guard text.utf8.starts(with: before.utf8) else { continue }
                let cut = text.utf8.index(text.utf8.startIndex, offsetBy: before.utf8.count)
                let added = text[cut...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !added.isEmpty { changes.append(.grew(id: message.id, added: added, text: text)) }
            } else {
                taken[message.id] = text
                changes.append(.new(.init(id: message.id, text: text)))
            }
        }
        return changes
    }
}
