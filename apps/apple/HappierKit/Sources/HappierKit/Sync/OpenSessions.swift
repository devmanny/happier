/// The conversations on screen, counted per window: the same one can be open in several windows
/// (Mac, iPad), and it stays open until the last of them closes it.
struct OpenSessions: Sequence {
    private var counts: [String: Int] = [:]

    mutating func open(_ id: String) {
        counts[id, default: 0] += 1
    }

    mutating func close(_ id: String) {
        guard let count = counts[id] else { return }
        counts[id] = count > 1 ? count - 1 : nil
    }

    func contains(_ id: String) -> Bool {
        counts[id] != nil
    }

    func makeIterator() -> Dictionary<String, Int>.Keys.Iterator {
        counts.keys.makeIterator()
    }
}
