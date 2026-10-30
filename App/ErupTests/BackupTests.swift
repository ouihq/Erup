import ScooterAnalytics
import SwiftData
import XCTest
@testable import Erup

@MainActor
final class BackupTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Ride.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func defaults() -> UserDefaults {
        let suite = "backup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000.25)

    private func summary(start: TimeInterval, regen: Double? = 1.5) -> RideSummary {
        RideSummary(
            startedAt: origin.addingTimeInterval(start), endedAt: origin.addingTimeInterval(start + 600), distanceKm: 3.2,
            averageSpeedKmh: 19, maxSpeedKmh: 24, energyWh: 55, batteryStart: 80, batteryEnd: 76,
            maxControllerTemperature: 41, maxMotorTemperature: 48, internalResistanceOhm: 0.17,
            samples: [
                RideSample(offset: 0, speedKmh: 10, powerWatts: 120, batteryPercent: 80, voltage: 41, controllerTemperature: 33, motorTemperature: 29,
                           sensors: PhoneSensors(altitudeMeters: 0, vibrationG: 0.04, peakG: 0.3, rotationDegPerSecond: 12)),
                RideSample(offset: 1, speedKmh: 12, powerWatts: -60, batteryPercent: 80, voltage: 40.8),
            ],
            regenWh: regen
        )
    }

    private let track = [TrackPoint(latitude: 52.52, longitude: 13.405, timestamp: Date(timeIntervalSinceReferenceDate: 800_000_001.5))]

    private func fill(_ container: ModelContainer, starts: [TimeInterval]) throws {
        for start in starts {
            container.mainContext.insert(try Ride.make(from: summary(start: start, regen: start == 0 ? nil : 1.5), track: track))
        }
        try container.mainContext.save()
    }

    private func backup(of container: ModelContainer, defaults: UserDefaults) async throws -> Data {
        try await BackupScheduler.makeData(container: container, defaults: defaults)
    }

    func testABackupRestoresEveryRideExactlyIntoAnEmptyDatabase() async throws {
        let source = try container()
        try fill(source, starts: [0, 3600, 7200])
        let data = try await backup(of: source, defaults: defaults())

        let archive = try await BackupService.decode(data)
        let target = try container()
        let result = try await BackupService.restore(archive, mode: .merge, includeSettings: false, into: target.mainContext, defaults: defaults())
        XCTAssertEqual(result.added, 3)

        let original = try source.mainContext.fetch(FetchDescriptor<Ride>(sortBy: [SortDescriptor(\.startedAt)]))
        let restored = try target.mainContext.fetch(FetchDescriptor<Ride>(sortBy: [SortDescriptor(\.startedAt)]))
        XCTAssertEqual(restored.map(\.id), original.map(\.id))
        XCTAssertEqual(restored.map(\.startedAt), original.map(\.startedAt))
        XCTAssertEqual(restored.map(\.regenWh), original.map(\.regenWh))
        XCTAssertEqual(restored[1].energyWh, 55)
        XCTAssertEqual(try restored[0].decodedSamples(), try original[0].decodedSamples())
        XCTAssertEqual(try restored[0].decodedTrack(), try original[0].decodedTrack())
        XCTAssertEqual(try restored[0].decodedSamples().first?.sensors?.vibrationG, 0.04)
    }

    func testMergeSkipsRidesThatAreAlreadyThereByIdentifierOrByTime() async throws {
        let source = try container()
        try fill(source, starts: [0, 3600])
        let archive = try await BackupService.decode(try await backup(of: source, defaults: defaults()))

        let target = try container()
        try fill(target, starts: [3600])   // the same moment but a different identifier
        let result = try await BackupService.restore(archive, mode: .merge, includeSettings: false, into: target.mainContext, defaults: defaults())
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Ride>()), 2)

        let again = try await BackupService.restore(archive, mode: .merge, includeSettings: false, into: target.mainContext, defaults: defaults())
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.skipped, 2)
    }

    func testReplaceMakesTheRidesExactlyTheBackupsRides() async throws {
        let source = try container()
        try fill(source, starts: [0])
        let archive = try await BackupService.decode(try await backup(of: source, defaults: defaults()))

        let target = try container()
        try fill(target, starts: [10_000, 20_000, 30_000])
        let result = try await BackupService.restore(archive, mode: .replace, includeSettings: false, into: target.mainContext, defaults: defaults())
        XCTAssertEqual(result.removed, 3)
        XCTAssertEqual(result.added, 1)
        let left = try target.mainContext.fetch(FetchDescriptor<Ride>())
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.startedAt, origin)
    }

    func testSettingsAreRestoredOnlyWhenAskedAndOnlyIfTheyAreOnTheList() async throws {
        let stored = defaults()
        stored.set(10, forKey: "rides.joinWithinMinutes")
        stored.set(true, forKey: "useMiles")
        stored.set("secret", forKey: "scooter.lockPIN")
        stored.set(Data([1, 2]), forKey: "pairedPeripheralID")
        let source = try container()
        let archive = try await BackupService.decode(try await backup(of: source, defaults: stored))
        XCTAssertEqual(archive.settings["rides.joinWithinMinutes"], .int(10))
        XCTAssertEqual(archive.settings["useMiles"], .bool(true))
        XCTAssertNil(archive.settings["scooter.lockPIN"])
        XCTAssertNil(archive.settings["pairedPeripheralID"])

        var tampered = archive
        tampered.settings["scooter.lockPIN"] = .string("1234")
        let target = defaults()
        let database = try container()   // kept alive: a context does not keep its container
        _ = try await BackupService.restore(tampered, mode: .merge, includeSettings: false, into: database.mainContext, defaults: target)
        XCTAssertNil(target.object(forKey: "rides.joinWithinMinutes"))

        let result = try await BackupService.restore(tampered, mode: .merge, includeSettings: true, into: database.mainContext, defaults: target)
        XCTAssertEqual(target.integer(forKey: "rides.joinWithinMinutes"), 10)
        XCTAssertTrue(target.bool(forKey: "useMiles"))
        XCTAssertNil(target.object(forKey: "scooter.lockPIN"), "a PIN in a file is never written")
        XCTAssertEqual(result.settings, 2)
    }

    func testFilesThatAreNotBackupsOrAreTooNewAreRefused() async throws {
        let garbage = Data("hello".utf8)
        do { _ = try await BackupService.decode(garbage); XCTFail("expected an error") } catch { XCTAssertEqual(error as? BackupError, .unreadable) }

        let other = Data(#"{"kind":"something-else","format":1}"#.utf8)
        do { _ = try await BackupService.decode(other); XCTFail("expected an error") } catch { XCTAssertEqual(error as? BackupError, .unreadable) }

        var archive = BackupArchive(createdAt: origin, app: "9.9", rides: [], settings: [:])
        archive.format = BackupArchive.currentFormat + 1
        let newer = try PackedData.pack(archive)
        do { _ = try await BackupService.decode(newer); XCTFail("expected an error") } catch {
            XCTAssertEqual(error as? BackupError, .newerFormat(BackupArchive.currentFormat + 1))
        }
    }

    func testTheSummaryDescribesTheBackup() async throws {
        let source = try container()
        try fill(source, starts: [0, 3600])
        let archive = try await BackupService.decode(try await backup(of: source, defaults: defaults()))
        let summary = BackupService.summary(of: archive)
        XCTAssertEqual(summary.rideCount, 2)
        XCTAssertEqual(summary.totalDistanceKm, 6.4, accuracy: 0.0001)
        XCTAssertEqual(summary.firstRide, origin)
        XCTAssertEqual(summary.lastRide, origin.addingTimeInterval(3600 + 600))
    }

    /// After a reinstall the rider picks the old folder to restore from. Backing up the empty phone must not push the real backup out.
    func testAnEmptyPhoneNeverReplacesTheBackupInTheFolder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("erup-scheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = defaults()
        try BackupFolder.remember(directory, defaults: defaults)
        func onDisk(_ name: String) throws -> ModelContainer {
            try ModelContainer(for: Ride.self, configurations: ModelConfiguration(url: directory.appendingPathComponent("\(name).store")))
        }

        let old = try onDisk("old")
        try fill(old, starts: [0, 3600])
        try await BackupScheduler(container: old, defaults: defaults).backUpNow()

        let fresh = try onDisk("fresh")
        do {
            try await BackupScheduler(container: fresh, defaults: defaults).backUpNow()
            XCTFail("an empty phone must not write a backup")
        } catch {
            XCTAssertEqual(error as? BackupError, .keptExisting)
        }
        do {
            try await BackupScheduler(container: try container(), defaults: defaults).backUpNow()
            XCTFail("a temporary store must not write a backup")
        } catch {
            XCTAssertEqual(error as? BackupError, .keptExisting)
        }
        let kept = try await BackupService.decode(try BackupFolder.latest(in: directory).data)
        XCTAssertEqual(kept.rides.count, 2)
    }

    func testAnEmptyBackupRoundTrips() async throws {
        let archive = try await BackupService.decode(try await backup(of: try container(), defaults: defaults()))
        XCTAssertTrue(archive.rides.isEmpty)
    }
}

final class BackupFolderTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("erup-backup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func defaults() -> UserDefaults {
        let suite = "backup-folder-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testTheLatestBackupIsWrittenAndThePreviousOneIsKept() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try BackupFolder.write(Data("one".utf8), to: folder)
        try BackupFolder.write(Data("two".utf8), to: folder)
        XCTAssertEqual(try BackupFolder.latest(in: folder).data, Data("two".utf8))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(BackupFolder.previousName)), Data("one".utf8))
    }

    func testAnEmptyOrMissingFolderIsReportedClearly() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertThrowsError(try BackupFolder.latest(in: folder)) { XCTAssertEqual($0 as? BackupError, .nothingInFolder) }
        let missing = folder.appendingPathComponent("gone")
        XCTAssertThrowsError(try BackupFolder.write(Data(), to: missing)) { XCTAssertEqual($0 as? BackupError, .folderUnavailable) }
    }

    func testTheFolderIsFoundAgainFromItsBookmark() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = defaults()
        XCTAssertNil(BackupFolder.resolved(defaults: defaults))
        try BackupFolder.remember(folder, defaults: defaults)
        XCTAssertEqual(BackupFolder.resolved(defaults: defaults)?.standardizedFileURL.path, folder.standardizedFileURL.path)
        BackupFolder.forget(defaults: defaults)
        XCTAssertNil(BackupFolder.resolved(defaults: defaults))
    }

    func testWithoutAFolderOtherNamedBackupsAreStillFound() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("manual".utf8).write(to: folder.appendingPathComponent("Erup-backup-2026-10-24.erupbackup"))
        XCTAssertEqual(try BackupFolder.latest(in: folder).data, Data("manual".utf8))
    }
}

final class BackupScheduleTests: XCTestCase {
    func testABackupIsDueWhenThereIsNoneOrTheLastOneIsOld() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertTrue(BackupScheduler.isDue(last: nil, now: now))
        XCTAssertFalse(BackupScheduler.isDue(last: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(BackupScheduler.isDue(last: now.addingTimeInterval(-21 * 3600), now: now))
    }

    func testTheFileIsNamedAfterTheDay() {
        let day = Date(timeIntervalSinceReferenceDate: 814_000_000)
        XCTAssertTrue(BackupService.fileName(now: day).hasPrefix("Erup-backup-2026-"))
        XCTAssertTrue(BackupService.fileName(now: day).hasSuffix(".erupbackup"))
    }
}
