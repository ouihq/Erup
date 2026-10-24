import Foundation
import ScooterAnalytics
import SwiftData

/// Makes a backup of the rides and settings, reads one back, and puts it onto this iPhone.
enum BackupService {
    enum RestoreMode: String, CaseIterable, Identifiable {
        /// Adds the rides this iPhone does not have yet and leaves the others alone.
        case merge
        /// Makes the rides on this iPhone exactly the ones in the backup.
        case replace

        var id: String { rawValue }
    }

    struct Summary: Equatable {
        let rideCount: Int
        let firstRide: Date?
        let lastRide: Date?
        let totalDistanceKm: Double
        let createdAt: Date
        let app: String
        let settingCount: Int
    }

    struct RestoreResult: Equatable {
        var added = 0
        var skipped = 0
        var removed = 0
        var settings = 0
    }

    /// A ride as read from the database, with its stored blobs. Made on the main actor, decoded elsewhere.
    struct RideSnapshot: Sendable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date
        let distanceKm: Double
        let averageSpeedKmh: Double
        let maxSpeedKmh: Double
        let energyWh: Double
        let batteryStart: Int
        let batteryEnd: Int
        let maxControllerTemperature: Int
        let maxMotorTemperature: Int
        let internalResistanceOhm: Double?
        let regenWh: Double?
        let samplesData: Data
        let trackData: Data?
    }

    // MARK: Making a backup

    @MainActor
    static func snapshots(of rides: [Ride]) -> [RideSnapshot] {
        rides.sorted { $0.startedAt < $1.startedAt }.map {
            RideSnapshot(
                id: $0.id, startedAt: $0.startedAt, endedAt: $0.endedAt, distanceKm: $0.distanceKm,
                averageSpeedKmh: $0.averageSpeedKmh, maxSpeedKmh: $0.maxSpeedKmh, energyWh: $0.energyWh,
                batteryStart: $0.batteryStart, batteryEnd: $0.batteryEnd,
                maxControllerTemperature: $0.maxControllerTemperature, maxMotorTemperature: $0.maxMotorTemperature,
                internalResistanceOhm: $0.internalResistanceOhm, regenWh: $0.regenWh,
                samplesData: $0.samplesData, trackData: $0.trackData
            )
        }
    }

    /// The compressed backup file. Decoding and compressing every ride is slow for a long history, so it runs off the main actor.
    static func makeData(
        snapshots: [RideSnapshot], settings: [String: SettingValue], appVersion: String, now: Date = .now
    ) async throws -> Data {
        try await Task.detached(priority: .utility) {
            var records: [RideRecord] = []
            records.reserveCapacity(snapshots.count)
            for snapshot in snapshots {
                records.append(RideRecord(
                    id: snapshot.id, startedAt: snapshot.startedAt, endedAt: snapshot.endedAt, distanceKm: snapshot.distanceKm,
                    averageSpeedKmh: snapshot.averageSpeedKmh, maxSpeedKmh: snapshot.maxSpeedKmh, energyWh: snapshot.energyWh,
                    batteryStart: snapshot.batteryStart, batteryEnd: snapshot.batteryEnd,
                    maxControllerTemperature: snapshot.maxControllerTemperature, maxMotorTemperature: snapshot.maxMotorTemperature,
                    internalResistanceOhm: snapshot.internalResistanceOhm, regenWh: snapshot.regenWh,
                    samples: try PackedData.decode([RideSample].self, from: snapshot.samplesData),
                    track: try snapshot.trackData.map { try PackedData.decode([TrackPoint].self, from: $0) } ?? []
                ))
            }
            let archive = BackupArchive(createdAt: now, app: appVersion, rides: records, settings: settings)
            return try PackedData.pack(archive)
        }.value
    }

    static func fileName(now: Date = .now) -> String {
        "Erup-backup-\(now.formatted(.iso8601.year().month().day())).erupbackup"
    }

    // MARK: Reading a backup

    private struct Header: Decodable {
        let kind: String?
        let format: Int?
    }

    static func decode(_ data: Data) async throws -> BackupArchive {
        try await Task.detached(priority: .userInitiated) { try decodeNow(data) }.value
    }

    static func decodeNow(_ data: Data) throws -> BackupArchive {
        let header: Header
        do {
            header = try PackedData.decode(Header.self, from: data)
        } catch {
            throw BackupError.unreadable
        }
        guard header.kind == BackupArchive.kind, let format = header.format else { throw BackupError.unreadable }
        guard format <= BackupArchive.currentFormat else { throw BackupError.newerFormat(format) }
        do {
            return try PackedData.decode(BackupArchive.self, from: data)
        } catch {
            throw BackupError.unreadable
        }
    }

    static func summary(of archive: BackupArchive) -> Summary {
        Summary(
            rideCount: archive.rides.count,
            firstRide: archive.rides.map(\.startedAt).min(),
            lastRide: archive.rides.map(\.endedAt).max(),
            totalDistanceKm: archive.rides.reduce(0) { $0 + $1.distanceKm },
            createdAt: archive.createdAt, app: archive.app, settingCount: archive.settings.count
        )
    }

    // MARK: Putting it back

    private struct PreparedRide: Sendable {
        let record: RideRecord
        let samplesData: Data
        let trackData: Data?
    }

    /// Writes the backup onto this iPhone. Everything is stored in one save, so a failure leaves the rides as they were.
    @MainActor
    static func restore(
        _ archive: BackupArchive, mode: RestoreMode, includeSettings: Bool, into context: ModelContext,
        defaults: UserDefaults = .standard
    ) async throws -> RestoreResult {
        let records = archive.rides
        let prepared = try await Task.detached(priority: .userInitiated) {
            try records.map { PreparedRide(
                record: $0, samplesData: try PackedData.pack($0.samples),
                trackData: $0.track.isEmpty ? nil : try PackedData.pack($0.track)
            ) }
        }.value

        var result = RestoreResult()
        do {
            let existing = try context.fetch(FetchDescriptor<Ride>())
            if mode == .replace {
                for ride in existing { context.delete(ride) }
                result.removed = existing.count
            }
            var knownIDs = mode == .merge ? Set(existing.map(\.id)) : []
            var knownTimes = mode == .merge ? Set(existing.map { TimeKey($0.startedAt, $0.endedAt) }) : []
            for item in prepared {
                let record = item.record
                let key = TimeKey(record.startedAt, record.endedAt)
                if knownIDs.contains(record.id) || knownTimes.contains(key) {
                    result.skipped += 1
                    continue
                }
                knownIDs.insert(record.id)
                knownTimes.insert(key)
                context.insert(Ride(
                    id: record.id, startedAt: record.startedAt, endedAt: record.endedAt, distanceKm: record.distanceKm,
                    averageSpeedKmh: record.averageSpeedKmh, maxSpeedKmh: record.maxSpeedKmh, energyWh: record.energyWh,
                    batteryStart: record.batteryStart, batteryEnd: record.batteryEnd,
                    maxControllerTemperature: record.maxControllerTemperature, maxMotorTemperature: record.maxMotorTemperature,
                    internalResistanceOhm: record.internalResistanceOhm, samplesData: item.samplesData, trackData: item.trackData,
                    regenWh: record.regenWh
                ))
                result.added += 1
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        if includeSettings { result.settings = BackupSettings.apply(archive.settings, to: defaults) }
        return result
    }

    /// Two rides are the same ride when they start and end within the same second, whatever their identifiers.
    private struct TimeKey: Hashable {
        let start: Int
        let end: Int

        init(_ start: Date, _ end: Date) {
            self.start = Int(start.timeIntervalSince1970.rounded())
            self.end = Int(end.timeIntervalSince1970.rounded())
        }
    }
}

/// The preferences a backup carries. A list of what is included, so pairing, the PIN and caches never end up in a file.
enum BackupSettings {
    private static let keys: Set<String> = [
        "appearance", "useMiles", "battery.capacityWh", "background.keepRunning", "connection.stallRecovery",
        "service.intervalKm", "service.lastServiceKm",
    ]
    private static let prefixes = ["rides.", "alerts."]

    static func isIncluded(_ key: String) -> Bool {
        keys.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }

    static func snapshot(of defaults: UserDefaults = .standard) -> [String: SettingValue] {
        var result: [String: SettingValue] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where isIncluded(key) {
            if let setting = SettingValue(value) { result[key] = setting }
        }
        return result
    }

    /// Writes the settings that are on the list and returns how many it wrote.
    @discardableResult
    static func apply(_ settings: [String: SettingValue], to defaults: UserDefaults = .standard) -> Int {
        var count = 0
        for (key, value) in settings where isIncluded(key) {
            defaults.set(value.object, forKey: key)
            count += 1
        }
        return count
    }
}
