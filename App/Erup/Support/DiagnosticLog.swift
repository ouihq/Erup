import Foundation

/// A rolling event log for debugging connection and background problems. Entries are written to a file as they
/// happen, so the log survives the app being suspended or killed, which is exactly when problems occur.
/// It never contains the PIN, the scooter's name or its Bluetooth identifiers.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    enum Category: String, Codable, CaseIterable, Sendable {
        case app, connection, stream, bridge, command, ride, error
    }

    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let date: Date
        let category: Category
        let message: String
        /// Whether the app was in the foreground when this happened.
        let foreground: Bool

        init(id: UUID = UUID(), date: Date = Date(), category: Category, message: String, foreground: Bool) {
            self.id = id
            self.date = date
            self.category = category
            self.message = message
            self.foreground = foreground
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var foreground = true
    private let capacity: Int
    private let fileURL: URL?
    private let writer = DispatchQueue(label: "me.ouihq.erup.diagnostics", qos: .utility)
    private var pendingBytes = 0
    private static let trimThreshold = 600_000

    init(directory: URL? = DiagnosticLog.defaultDirectory, capacity: Int = 2_000) {
        self.capacity = capacity
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent("diagnostics.jsonl")
        } else {
            fileURL = nil
        }
        entries = loadFromDisk()
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    // MARK: Writing

    var isForeground: Bool {
        get { lock.withLock { foreground } }
        set {
            let changed = lock.withLock { () -> Bool in
                defer { foreground = newValue }
                return foreground != newValue
            }
            if changed { log(.app, newValue ? "app became active" : "app left the foreground") }
        }
    }

    func log(_ category: Category, _ message: String) {
        let entry = lock.withLock { () -> Entry in
            let entry = Entry(category: category, message: message, foreground: foreground)
            entries.append(entry)
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
            return entry
        }
        append(entry)
    }

    func clear() {
        lock.withLock { entries.removeAll() }
        writer.async { [fileURL] in
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        }
        log(.app, "log cleared")
    }

    // MARK: Reading

    var snapshot: [Entry] { lock.withLock { entries } }

    /// Waits for pending file writes, so a test or an export reads what was logged.
    func flush() { writer.sync {} }

    /// A plain text report: facts about the app and phone, then every event, oldest first.
    func report(header: [(String, String)], frames: [String] = []) -> String {
        var lines = ["Erup diagnostics", "Generated \(Date().formatted(Self.stampStyle))", ""]
        lines += header.map { "\($0.0): \($0.1)" }
        let events = snapshot
        lines += ["", "Events (\(events.count), oldest first). fg = app on screen, bg = in the background", ""]
        lines += events.map { Self.line(for: $0) }
        if !frames.isEmpty {
            lines += ["", "Frames (\(frames.count))", ""] + frames
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static let stampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func line(for entry: Entry) -> String {
        "\(entry.date.formatted(stampStyle)) \(entry.foreground ? "fg" : "bg") \(entry.category.rawValue): \(entry.message)"
    }

    // MARK: Persistence

    private func loadFromDisk() -> [Entry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        let loaded = data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
        return Array(loaded.suffix(capacity))
    }

    private func append(_ entry: Entry) {
        guard let fileURL, var encoded = try? JSONEncoder().encode(entry) else { return }
        encoded.append(UInt8(ascii: "\n"))
        let data = encoded
        writer.async { [self] in
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
            pendingBytes += data.count
            if pendingBytes > Self.trimThreshold { trimFile() }
        }
    }

    /// Keeps the file from growing without limit: rewrites it with only the entries still in memory.
    private func trimFile() {
        pendingBytes = 0
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        var output = Data()
        for entry in snapshot {
            if let line = try? encoder.encode(entry) { output.append(line); output.append(UInt8(ascii: "\n")) }
        }
        try? output.write(to: fileURL, options: .atomic)
    }
}
