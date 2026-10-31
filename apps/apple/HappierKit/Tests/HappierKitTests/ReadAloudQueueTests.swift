import Foundation
import Testing
@testable import HappierKit

/// Auto read: each new agent message is read in turn; one arriving mid-reading waits its turn
/// instead of cutting in, and the player can jump a whole message back or ahead.
struct ReadAloudQueueTests {
    @Test func moreOfAMessageIsReadWhereverItIs() {
        var queue = ReadAloudQueue()
        _ = queue.enqueue(a)
        _ = queue.enqueue(b)
        // Being read now: the new part is appended to this reading.
        #expect(queue.grow(id: "a", text: "First. More.", added: "More.") == .appendToCurrent("More."))
        // Still waiting: it just waits with all its text.
        #expect(queue.grow(id: "b", text: "Second. More.", added: "More.") == .updated)
        #expect(queue.advance() == .init(id: "b", text: "Second. More."))
        // Already read: the new part comes back as its own block, after the others.
        #expect(queue.grow(id: "a", text: "First. More. Even more.", added: "Even more.") == .queued)
        #expect(queue.waiting == 1)
        #expect(queue.advance()?.text == "Even more.")
        // Idle: it starts right away.
        #expect(queue.advance() == nil)
        if case .started(let block) = queue.grow(id: "b", text: "Second. More. Last.", added: "Last.") {
            #expect(block.text == "Last.")
        } else {
            Issue.record("An idle queue reads the new part at once")
        }
    }

    private let a = ReadAloudQueue.Block(id: "a", text: "First.")
    private let b = ReadAloudQueue.Block(id: "b", text: "Second.")
    private let c = ReadAloudQueue.Block(id: "c", text: "Third.")

    @Test func aMessageArrivingMidReadingWaitsItsTurn() {
        var queue = ReadAloudQueue()
        #expect(queue.enqueue(a) == a)          // nothing playing: starts now
        #expect(queue.enqueue(b) == nil)        // a is playing: b waits
        #expect(queue.enqueue(b) == nil)        // and only once
        #expect(queue.current == a)
        #expect(queue.waiting == 1)
        #expect(queue.advance() == b)           // a finished
        #expect(queue.advance() == nil)         // b finished, nothing left: idle
        #expect(queue.current == nil)
        #expect(queue.enqueue(c) == c)          // idle again: the next one starts right away
    }

    @Test func jumpsAWholeMessageBackAndAhead() {
        var queue = ReadAloudQueue()
        _ = queue.enqueue(a)
        _ = queue.enqueue(b)
        _ = queue.enqueue(c)
        #expect(!queue.hasPrevious)
        #expect(queue.advance() == b)
        #expect(queue.hasPrevious && queue.hasNext)
        #expect(queue.previous() == a)
        #expect(queue.advance() == b)
        #expect(queue.advance() == c)
        #expect(!queue.hasNext)
        // Finished the last one: "back" replays it.
        #expect(queue.advance() == nil)
        #expect(queue.previous() == c)
    }

    @Test func readingOneMessageByHandReplacesTheQueue() {
        var queue = ReadAloudQueue()
        _ = queue.enqueue(a)
        _ = queue.enqueue(b)
        queue.play(c)
        #expect(queue.current == c)
        #expect(queue.waiting == 0)
        #expect(!queue.hasPrevious)
    }
}

/// Which agent messages auto read takes: only ones that arrived after it was turned on, and only
/// once complete (followed by something else, or the turn over), never the thinking.
struct AutoReadCursorTests {
    /// Agent messages stream in: one already taken keeps growing, and only the new part is read.
    @Test func aMessageThatKeepsGrowingHandsOverOnlyTheNewPart() {
        var cursor = AutoReadCursor(existing: [])
        #expect(cursor.take([agent("m", "Hola."), user("u")], turnActive: true) == [.new(.init(id: "m", text: "Hola."))])
        #expect(cursor.take([agent("m", "Hola. Ya revisé el código."), user("u")], turnActive: true)
            == [.grew(id: "m", added: "Ya revisé el código.", text: "Hola. Ya revisé el código.")])
        #expect(cursor.take([agent("m", "Hola. Ya revisé el código."), user("u")], turnActive: false).isEmpty)
    }

    private func agent(_ id: String, _ text: String, thinking: Bool = false) -> ChatItem {
        .agentText(AgentText(id: id, text: text, isThinking: thinking, createdAt: .now))
    }

    private func user(_ id: String) -> ChatItem {
        .userText(UserText(id: id, text: "hi", createdAt: .now, localId: nil, isPending: false))
    }

    @Test func readsOnlyNewCompleteMessages() {
        var cursor = AutoReadCursor(existing: [agent("old", "Already here.")])
        // Still being written at the end of a running turn: not yet.
        #expect(cursor.take([agent("old", "Already here."), user("u"), agent("m1", "Work")], turnActive: true).isEmpty)
        // Something came after it: it's complete.
        let next = cursor.take([agent("old", "Already here."), user("u"), agent("m1", "Working on it."), agent("t", "…", thinking: true), agent("m2", "Done")],
                               turnActive: true)
        #expect(next == [.new(.init(id: "m1", text: "Working on it."))])
        // The turn ended: the last one is complete too, and nothing is read twice.
        let last = cursor.take([agent("old", "Already here."), user("u"), agent("m1", "Working on it."), agent("t", "…", thinking: true), agent("m2", "Done.")],
                               turnActive: false)
        #expect(last == [.new(.init(id: "m2", text: "Done."))])
        #expect(cursor.take([agent("m2", "Done.")], turnActive: false).isEmpty)
    }
}
