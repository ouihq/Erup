import Foundation

struct ScooterSnapshot: Codable, Equatable, Sendable {
    struct RideSummary: Codable, Equatable, Sendable {
        var startedAt: Date
        var distanceKm: Double
        var duration: TimeInterval
        var averageSpeedKmh: Double
    }

    var updatedAt: Date
    var isConnected: Bool
    var batteryPercent: Int?
    var rangeKm: Double?
    var speedKmh: Double
    var gearRaw: UInt8?
    var headlightOn: Bool
    var isLocked: Bool
    var tripKm: Double?
    var totalKm: Double?
    var controllerTemperature: Int?
    var motorTemperature: Int?
    var current: Double?
    var lastSeen: Date?
    var lastRide: RideSummary?
    var usesMiles: Bool

    static let empty = ScooterSnapshot(
        updatedAt: .distantPast, isConnected: false, batteryPercent: nil, rangeKm: nil, speedKmh: 0,
        gearRaw: nil, headlightOn: false, isLocked: false, tripKm: nil, totalKm: nil,
        controllerTemperature: nil, motorTemperature: nil, current: nil, lastSeen: nil, lastRide: nil, usesMiles: false
    )

    static let preview = ScooterSnapshot(
        updatedAt: .now, isConnected: true, batteryPercent: 76, rangeKm: 21.4, speedKmh: 18.4,
        gearRaw: 1, headlightOn: true, isLocked: false, tripKm: 5.2, totalKm: 318.4,
        controllerTemperature: 34, motorTemperature: 41, current: 4, lastSeen: .now,
        lastRide: RideSummary(startedAt: .now.addingTimeInterval(-7200), distanceKm: 6.8, duration: 1_260, averageSpeedKmh: 19.4),
        usesMiles: false
    )
}

enum SnapshotStore {
    private static let fileName = "snapshot.json"

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)?
            .appendingPathComponent(fileName)
    }

    /// Deletes the last snapshot the widgets would show.
    static func remove() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    enum StoreError: Error, LocalizedError {
        case appGroupUnavailable

        var errorDescription: String? {
            "The shared App Group container is unavailable. Check the App Group capability."
        }
    }

    static func load() -> ScooterSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ScooterSnapshot.self, from: data)
    }

    static func save(_ snapshot: ScooterSnapshot) throws {
        guard let url else { throw StoreError.appGroupUnavailable }
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
