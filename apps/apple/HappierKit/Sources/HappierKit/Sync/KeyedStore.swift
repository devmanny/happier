import Observation

/// A dictionary observed entry by entry. An `@Observable` dictionary property notifies every
/// reader on every write, so a message in one session redrew every view showing any session
/// (open menus visibly pulsed). Here a view reading one entry redraws only when that entry
/// changes, or when entries come and go; reading `values`, `keys` or `count` observes them all.
@MainActor
public final class KeyedStore<Value> {
    private var boxes: [String: ObservedBox<Value>] = [:]
    private let membership = ObservedBox(0)
    /// Writing an equal value notifies no one.
    private let isSame: (Value, Value) -> Bool

    public init(isSame: @escaping (Value, Value) -> Bool) {
        self.isSame = isSame
    }

    public internal(set) subscript(key: String) -> Value? {
        get {
            _ = membership.value
            return boxes[key]?.value
        }
        set {
            if let newValue {
                if let box = boxes[key] {
                    // "Same" only spares the readers; the new value is kept either way.
                    if isSame(box.value, newValue) { box.replaceQuietly(newValue) } else { box.value = newValue }
                } else {
                    boxes[key] = ObservedBox(newValue)
                    membership.value += 1
                }
            } else if boxes.removeValue(forKey: key) != nil {
                membership.value += 1
            }
        }
    }

    public var values: [Value] {
        _ = membership.value
        return boxes.values.map(\.value)
    }

    public var keys: [String] {
        _ = membership.value
        return Array(boxes.keys)
    }

    public var count: Int {
        _ = membership.value
        return boxes.count
    }

    /// The whole set at once (a full sync): unchanged entries stay quiet.
    func replaceAll(with next: [String: Value]) {
        var membershipChanged = false
        for (key, value) in next {
            if let box = boxes[key] {
                if isSame(box.value, value) { box.replaceQuietly(value) } else { box.value = value }
            } else {
                boxes[key] = ObservedBox(value)
                membershipChanged = true
            }
        }
        for key in boxes.keys where next[key] == nil {
            boxes[key] = nil
            membershipChanged = true
        }
        if membershipChanged { membership.value += 1 }
    }

    func removeAll() {
        guard !boxes.isEmpty else { return }
        boxes = [:]
        membership.value += 1
    }
}

extension KeyedStore where Value: Equatable {
    public convenience init() {
        self.init(isSame: { $0 == $1 })
    }
}

@MainActor
@Observable
final class ObservedBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// Stores a value its readers needn't redraw for, without telling them.
    func replaceQuietly(_ newValue: Value) {
        _value = newValue
    }
}
