import Foundation

/// Persisted provider reports from `/v1/usage/query`, independent of context occupancy and quota.
/// Coverage depends on the producer: some older agents replace their latest report instead of
/// accumulating every turn. These are recorded tokens, not a guaranteed lifetime bill.
public struct SessionTokenUsage: Equatable, Sendable {
    public let tokens: Int?

    public init(response: JSONValue) {
        guard let rows = response["usage"]?.arrayValue, !rows.isEmpty else {
            tokens = nil
            return
        }
        var total = 0
        var hasTokens = false
        for row in rows {
            // The server retains costs while excluding ambiguous legacy/context-only tokens.
            if row["tokens"]?.objectValue?.isEmpty == true { continue }
            guard let value = row["tokens"]?["total"]?.doubleValue,
                  let count = Int(exactly: value), count >= 0 else {
                tokens = nil
                return
            }
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow else { tokens = nil; return }
            total = sum.partialValue
            hasTokens = true
        }
        tokens = hasTokens ? total : nil
    }
}

/// A tree subtotal over the sessions known to the client. Each session ID contributes once.
public struct SessionTokenSummary: Equatable, Sendable {
    public let own: Int?
    public let descendants: Int?
    public let descendantCount: Int
    public let missingCount: Int
    public var total: Int? {
        guard own != nil || descendants != nil else { return nil }
        return (own ?? 0) + (descendants ?? 0)
    }

    public static func memberIds(_ sessionId: String, parents: [String: String]) -> Set<String> {
        let children = Dictionary(grouping: parents.keys, by: { parents[$0]! })
        var members: Set<String> = [sessionId]
        var pending = [sessionId]
        while let id = pending.popLast() {
            for child in children[id] ?? [] where members.insert(child).inserted {
                pending.append(child)
            }
        }
        return members
    }

    public init(sessionId: String, parents: [String: String], usage: [String: SessionTokenUsage]) {
        let members = Self.memberIds(sessionId, parents: parents)
        own = usage[sessionId]?.tokens
        let childTokens = members.filter { $0 != sessionId }.compactMap { usage[$0]?.tokens }
        descendants = childTokens.isEmpty ? nil : childTokens.reduce(0, +)
        descendantCount = members.count - 1
        missingCount = members.filter { usage[$0]?.tokens == nil }.count
    }
}
