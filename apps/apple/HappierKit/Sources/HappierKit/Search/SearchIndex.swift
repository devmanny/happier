import Foundation

/// A field of a searchable document. `rank` orders fields by importance (0 = most important, e.g.
/// a title); `tag` says which field it is to whoever shows the result.
public struct SearchField: Sendable, Equatable {
    public let rank: Int
    public let tag: String
    public let text: String

    public init(rank: Int, tag: String, text: String) {
        self.rank = rank
        self.tag = tag
        self.text = text
    }
}

/// Where a query word matched: a field of the document and the range of its text.
public struct SearchMatch: Sendable, Equatable {
    public let field: Int
    public let range: Range<String.Index>
}

/// One result, with what its ranking was decided on.
public struct SearchHit<ID: Hashable & Sendable>: Sendable {
    public let id: ID
    /// Query words found in the document.
    public let matchedWords: Int
    /// Typos summed over the words found.
    public let typos: Int
    /// The ranks of the fields each found word matched best in, summed (lower is better).
    public let fieldScore: Int
    /// Words that matched whole, not as a prefix or with typos.
    public let exactWords: Int
    /// How far apart consecutive query words are in the document (lower is closer).
    public let proximity: Int
    /// Every place a query word matched, in field order.
    public let matches: [SearchMatch]
}

/// The one in-memory, typo-tolerant full-text search of the app, ranked like Meilisearch: case and
/// accents don't count, the last word matches as a prefix while it's being typed, typos are allowed
/// by word length (none up to 4 letters, 1 up to 8, 2 from 9; Damerau-Levenshtein), and words match
/// in any order. Results rank by words found, then fewer typos, then the more important field, then
/// exact over prefix, then words closer together; the caller breaks remaining ties.
///
/// Everything stays on the device (task and session contents are end-to-end encrypted). Documents
/// are added, replaced and removed one at a time, so the index follows live changes; a query scans
/// the vocabulary (distinct words), not the documents.
public final class SearchIndex<ID: Hashable & Sendable> {
    private struct Posting {
        let doc: Int
        let field: Int
        let position: Int
        let range: Range<String.Index>
    }

    /// How one query word matched one document: its best match and every place it matched.
    private struct WordHit {
        var typos: Int
        var fieldRank: Int
        var exact: Bool
        var postings: [Posting] = []
    }

    private struct Document {
        let id: ID
        let fields: [SearchField]
        let terms: Set<[UInt32]>
    }

    private var documents: [Int: Document] = [:]
    private var slots: [ID: Int] = [:]
    private var nextSlot = 0
    private var postings: [[UInt32]: [Posting]] = [:]

    public init() {}

    public var count: Int { documents.count }

    public func contains(_ id: ID) -> Bool { slots[id] != nil }

    /// Adds the document, or replaces it when `id` is indexed already.
    public func upsert(_ id: ID, fields: [SearchField]) {
        remove(id)
        let slot = nextSlot
        nextSlot += 1
        var terms = Set<[UInt32]>()
        var position = 0
        for (fieldIndex, field) in fields.enumerated() {
            for token in Self.tokens(field.text) {
                postings[token.folded, default: []].append(Posting(doc: slot, field: fieldIndex, position: position, range: token.range))
                terms.insert(token.folded)
                position += 1
            }
            // Words of different fields are never "together".
            position += 8
        }
        documents[slot] = Document(id: id, fields: fields, terms: terms)
        slots[id] = slot
    }

    public func remove(_ id: ID) {
        guard let slot = slots.removeValue(forKey: id), let document = documents.removeValue(forKey: slot) else { return }
        for term in document.terms {
            postings[term]?.removeAll { $0.doc == slot }
            if postings[term]?.isEmpty == true { postings[term] = nil }
        }
    }

    public func fields(of id: ID) -> [SearchField]? {
        slots[id].flatMap { documents[$0]?.fields }
    }

    /// The documents matching at least one query word, best first; `tieBreak` orders equal ranks.
    public func search(_ query: String, tieBreak: (ID, ID) -> Bool = { _, _ in false }) -> [SearchHit<ID>] {
        var words: [[UInt32]] = []
        for token in Self.tokens(query) where !words.contains(token.folded) { words.append(token.folded) }
        guard !words.isEmpty else { return [] }
        // Only the last word is still being typed, so only it matches as a prefix.
        let prefixWord = Self.endsInsideWord(query) ? words.count - 1 : -1

        var found: [Int: [Int: WordHit]] = [:]
        for (wordIndex, word) in words.enumerated() {
            let allowed = Self.allowedTypos(word.count)
            for (term, list) in postings {
                guard let match = Self.match(word, term, prefix: wordIndex == prefixWord, allowed: allowed) else { continue }
                for posting in list {
                    guard let document = documents[posting.doc] else { continue }
                    let rank = document.fields[posting.field].rank
                    var hit = found[posting.doc]?[wordIndex] ?? WordHit(typos: .max, fieldRank: .max, exact: false)
                    if (match.typos, rank, match.exact ? 0 : 1) < (hit.typos, hit.fieldRank, hit.exact ? 0 : 1) {
                        hit.typos = match.typos
                        hit.fieldRank = rank
                        hit.exact = match.exact
                    }
                    hit.postings.append(posting)
                    found[posting.doc, default: [:]][wordIndex] = hit
                }
            }
        }

        var hits: [SearchHit<ID>] = []
        hits.reserveCapacity(found.count)
        for (slot, byWord) in found {
            guard let document = documents[slot] else { continue }
            let ordered = byWord.keys.sorted()
            var proximity = 0
            for (a, b) in zip(ordered, ordered.dropFirst()) {
                var closest = 8
                for left in byWord[a]!.postings {
                    for right in byWord[b]!.postings where right.field == left.field {
                        closest = min(closest, abs(right.position - left.position))
                    }
                }
                proximity += closest
            }
            let matches = byWord.values.flatMap(\.postings)
                .sorted { ($0.field, $0.position) < ($1.field, $1.position) }
                .map { SearchMatch(field: $0.field, range: $0.range) }
            hits.append(SearchHit(
                id: document.id,
                matchedWords: byWord.count,
                typos: byWord.values.reduce(0) { $0 + $1.typos },
                fieldScore: byWord.values.reduce(0) { $0 + $1.fieldRank },
                exactWords: byWord.values.filter(\.exact).count,
                proximity: proximity,
                matches: matches))
        }
        return hits.sorted { a, b in
            if a.matchedWords != b.matchedWords { return a.matchedWords > b.matchedWords }
            if a.typos != b.typos { return a.typos < b.typos }
            if a.fieldScore != b.fieldScore { return a.fieldScore < b.fieldScore }
            if a.exactWords != b.exactWords { return a.exactWords > b.exactWords }
            if a.proximity != b.proximity { return a.proximity < b.proximity }
            return tieBreak(a.id, b.id)
        }
    }

    // MARK: Words

    /// Typos a query word of this many letters may have.
    static func allowedTypos(_ length: Int) -> Int {
        length <= 4 ? 0 : length <= 8 ? 1 : 2
    }

    struct Token {
        let range: Range<String.Index>
        let folded: [UInt32]
    }

    /// The words of `text` (letters, marks and digits), each folded to lower case without accents,
    /// with its range in `text`.
    static func tokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let scalars = text.unicodeScalars
        var start: String.Index?
        var index = scalars.startIndex
        func close(at end: String.Index) {
            guard let begin = start else { return }
            let folded = String(scalars[begin..<end])
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            let values = folded.unicodeScalars.filter { !CharacterSet.nonBaseCharacters.contains($0) }.map(\.value)
            if !values.isEmpty { tokens.append(Token(range: begin..<end, folded: values)) }
            start = nil
        }
        while index < scalars.endIndex {
            if CharacterSet.alphanumerics.contains(scalars[index]) {
                if start == nil { start = index }
            } else {
                close(at: index)
            }
            index = scalars.index(after: index)
        }
        close(at: scalars.endIndex)
        return tokens
    }

    private static func endsInsideWord(_ query: String) -> Bool {
        query.unicodeScalars.last.map { CharacterSet.alphanumerics.contains($0) } ?? false
    }

    /// How `word` (from the query) matches `term` (from a document), if it does.
    static func match(_ word: [UInt32], _ term: [UInt32], prefix: Bool, allowed: Int) -> (typos: Int, exact: Bool)? {
        if word == term { return (0, true) }
        if prefix, term.count > word.count, term.starts(with: word) { return (0, false) }
        guard allowed > 0 else { return nil }
        var best: Int?
        if abs(word.count - term.count) <= allowed, let distance = distance(word, term, limit: allowed) { best = distance }
        if prefix {
            let shortest = max(1, word.count - allowed), longest = min(term.count - 1, word.count + allowed)
            if shortest <= longest {
                for length in shortest...longest {
                    if let distance = distance(word, Array(term.prefix(length)), limit: allowed) { best = min(best ?? .max, distance) }
                }
            }
        }
        return best.map { ($0, false) }
    }

    /// Damerau-Levenshtein (optimal string alignment) distance, or nil once it exceeds `limit`.
    static func distance(_ a: [UInt32], _ b: [UInt32], limit: Int) -> Int? {
        if abs(a.count - b.count) > limit { return nil }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) <= limit ? max(a.count, b.count) : nil }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { value = min(value, previous2[j - 2] + 1) }
                current[j] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > limit { return nil }
            (previous2, previous, current) = (previous, current, previous2)
        }
        let result = previous[b.count]
        return result <= limit ? result : nil
    }
}

/// A short piece of a field around its first match, with the matched ranges to highlight.
public struct SearchSnippet: Sendable, Equatable {
    public let text: String
    public let highlights: [Range<String.Index>]

    /// Up to `before` characters before the first match and `after` after it, cut with "…".
    public init(text full: String, matches: [Range<String.Index>], before: Int = 30, after: Int = 70) {
        guard let first = matches.first else {
            self.text = String(full.prefix(before + after))
            self.highlights = []
            return
        }
        let start = full.index(first.lowerBound, offsetBy: -before, limitedBy: full.startIndex) ?? full.startIndex
        let end = full.index(first.upperBound, offsetBy: after, limitedBy: full.endIndex) ?? full.endIndex
        let lead = start > full.startIndex ? "…" : ""
        let tail = end < full.endIndex ? "…" : ""
        let body = full[start..<end]
        let text = lead + body.replacingOccurrences(of: "\n", with: " ") + tail
        self.text = text
        // Same length (only newlines became spaces): shift each range into the snippet.
        let offset = lead.count
        self.highlights = matches.compactMap { range in
            guard range.lowerBound >= start, range.upperBound <= end else { return nil }
            let lower = full.distance(from: start, to: range.lowerBound) + offset
            let length = full.distance(from: range.lowerBound, to: range.upperBound)
            guard let from = text.index(text.startIndex, offsetBy: lower, limitedBy: text.endIndex),
                  let to = text.index(from, offsetBy: length, limitedBy: text.endIndex) else { return nil }
            return from..<to
        }
    }
}
