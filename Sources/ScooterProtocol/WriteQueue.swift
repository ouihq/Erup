public struct WriteQueue: Sendable {
    public enum Channel: Sendable, Equatable {
        case data
        case command
    }

    public struct Item: Sendable, Equatable {
        public let channel: Channel
        public let bytes: [UInt8]
        public let isKeepAlive: Bool

        public init(channel: Channel, bytes: [UInt8], isKeepAlive: Bool = false) {
            self.channel = channel
            self.bytes = bytes
            self.isKeepAlive = isKeepAlive
        }
    }

    private var items: [Item] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    /// The next item, without removing it, so a write that has to wait is not lost.
    public var first: Item? { items.first }
    public var count: Int { items.count }

    @discardableResult
    public mutating func enqueue(_ item: Item) -> Bool {
        if item.isKeepAlive {
            guard !items.contains(where: \.isKeepAlive) else { return false }
            items.append(item)
        } else {
            let index = items.firstIndex(where: \.isKeepAlive) ?? items.endIndex
            items.insert(item, at: index)
        }
        return true
    }

    public mutating func popFirst() -> Item? {
        items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func removeAll() {
        items.removeAll()
    }
}
