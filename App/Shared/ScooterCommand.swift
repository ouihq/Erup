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
        try write(try read() + [QueuedCommand(id: UUID(), command: command, date: Date())])
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
