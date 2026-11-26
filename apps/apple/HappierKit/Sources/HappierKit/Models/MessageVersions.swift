import Foundation

/// One version of a message: the conversation it's in and its seq there.
public struct MessageVersion: Equatable, Hashable, Sendable {
    public let sessionId: String
    public let seq: Int

    public init(sessionId: String, seq: Int) {
        self.sessionId = sessionId
        self.seq = seq
    }
}

/// A message's versions, oldest first, and which one this is.
public struct MessageVersions: Equatable, Sendable {
    public let all: [MessageVersion]
    public let current: Int
}
