import Foundation

enum ScooterCommand: Codable, Equatable, Sendable {
    case headlight(Bool)
    case locked(Bool)
    case gear(UInt8)
}

struct QueuedCommand: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let command: ScooterCommand
    let date: Date
}

enum CommandQueueFile {
    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)?
            .appendingPathComponent("commands.json")
    }

    static func read() throws -> [QueuedCommand] {
        guard let url else { throw SnapshotStore.StoreError.appGroupUnavailable }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([QueuedCommand].self, from: Data(contentsOf: url))
    }

    static func write(_ commands: [QueuedCommand]) throws {
        guard let url else { throw SnapshotStore.StoreError.appGroupUnavailable }
        try JSONEncoder().encode(commands).write(to: url, options: .atomic)
    }

    static func enqueue(_ command: ScooterCommand) throws {
        try update { $0 + [QueuedCommand(id: UUID(), command: command, date: Date())] }
    }

    /// Removes the commands the app has taken, keeping any the widget added meanwhile.
    static func remove(_ taken: [QueuedCommand]) throws {
        let ids = Set(taken.map(\.id))
        try update { $0.filter { !ids.contains($0.id) } }
    }

    /// The widget extension and the app both change the file, so each read-change-write is coordinated across processes.
    private static func update(_ change: ([QueuedCommand]) -> [QueuedCommand]) throws {
        guard let url else { throw SnapshotStore.StoreError.appGroupUnavailable }
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { _ in
            do { try write(change(try read())) } catch { thrown = error }
        }
        if let error = thrown ?? coordinationError { throw error }
    }
}

final class DarwinObserver: @unchecked Sendable {
    static let commandName = "me.ouihq.erup.command"

    private let handler: @Sendable () -> Void

    init(name: String = commandName, handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue().handler()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    static func post(name: String = commandName) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true
        )
    }
}

enum CommandError: Error, LocalizedError {
    case notConfirmed

    var errorDescription: String? {
        "Erup could not confirm the change. Open Erup and make sure the scooter is connected."
    }
}

/// Runs a command in the app process when an executor is registered. In the widget extension no executor
/// exists, so the command is queued in the App Group, the app is signalled, and the shared snapshot is
/// polled for the result.
@MainActor
final class ScooterCommandCenter {
    static let shared = ScooterCommandCenter()

    var executor: (@MainActor (ScooterCommand) async throws -> Void)?

    func run(_ command: ScooterCommand) async throws {
        if let executor {
            try await executor(command)
            return
        }
        try CommandQueueFile.enqueue(command)
        DarwinObserver.post()
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(150))
            if let snapshot = SnapshotStore.load(), Date().timeIntervalSince(snapshot.updatedAt) < 10,
               Self.snapshot(snapshot, reflects: command) {
                return
            }
        }
        throw CommandError.notConfirmed
    }

    private static func snapshot(_ snapshot: ScooterSnapshot, reflects command: ScooterCommand) -> Bool {
        switch command {
        case .headlight(let on): snapshot.headlightOn == on
        case .locked(let locked): snapshot.isLocked == locked
        case .gear(let raw): snapshot.gearRaw == raw
        }
    }
}
