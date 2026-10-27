import ScooterAnalytics
import SwiftData
import XCTest
@testable import Erup

@MainActor
final class DataAndNoticeTests: XCTestCase {
    func testNoticesOutliveTheBannerAndCanBeRemovedAndCleared() {
        let store = ScooterStore.preview()
        store.report("The link dropped")
        XCTAssertEqual(store.alertMessage, "The link dropped")
        XCTAssertEqual(store.unreadNoticeCount, 1)

        store.dismissAlert()
        XCTAssertNil(store.alertMessage)
        XCTAssertEqual(store.notices.count, 1, "dismissing the banner keeps the entry")

        store.report("The link dropped")
        XCTAssertEqual(store.notices.count, 1, "the same problem repeating is not listed twice")

        store.report("Rename failed")
        XCTAssertEqual(store.notices.count, 2)
        store.markNoticesRead()
        XCTAssertEqual(store.unreadNoticeCount, 0)

        store.removeNotice(store.notices[0].id)
        XCTAssertEqual(store.notices.map(\.message), ["Rename failed"])
        store.clearNotices()
        XCTAssertTrue(store.notices.isEmpty)
        XCTAssertNil(store.alertMessage)
    }

    func testExportContainsEveryRideAndNoSecrets() throws {
        let container = Ride.previewContainer()
        let rides = try container.mainContext.fetch(FetchDescriptor<Ride>())
        XCTAssertGreaterThan(rides.count, 10)
        PINVault.pin = "917263"
        defer { PINVault.pin = nil }

        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let root = try DataExporter.writePackage(
            records: rides.map(DataExporter.Record.init), info: .init(appVersion: "1.0", useMiles: false, zydCode: "012345"),
            options: .init(detailedFiles: true), in: parent
        )
        let ridesCSV = try String(contentsOf: root.appendingPathComponent("rides.csv"), encoding: .utf8)
        XCTAssertEqual(ridesCSV.split(separator: "\n").count, rides.count + 1)
        let samplesCSV = try String(contentsOf: root.appendingPathComponent("samples.csv"), encoding: .utf8)
        XCTAssertGreaterThan(samplesCSV.split(separator: "\n").count, rides.count)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("rides").path).count, rides.count)
        let summary = try String(contentsOf: root.appendingPathComponent("summary.json"), encoding: .utf8)
        XCTAssertTrue(summary.contains("\"rides\" : \(rides.count)"))

        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.hasDirectoryPath == false {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("917263"), "\(file.lastPathComponent) must not contain the PIN")
        }

        let zip = try DataExporter.zip(root)
        defer { try? FileManager.default.removeItem(at: zip) }
        let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000)
    }

    func testResetDeletesRidesPINAndNotices() async throws {
        let container = Ride.previewContainer()
        let store = ScooterStore.preview()
        store.report("something")
        PINVault.pin = "654321"
        UserDefaults.standard.set(true, forKey: "useMiles")

        try await AppReset.perform(store: store, context: container.mainContext)

        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Ride>()), 0)
        XCTAssertNil(PINVault.pin)
        XCTAssertTrue(store.notices.isEmpty)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "useMiles"))
    }

    func testExportHonoursPeriodAndContents() throws {
        let container = Ride.previewContainer()
        let rides = try container.mainContext.fetch(FetchDescriptor<Ride>())
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("export-options-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
        let expected = rides.filter { $0.startedAt >= cutoff }.count
        XCTAssertGreaterThan(expected, 0)
        XCTAssertLessThan(expected, rides.count)

        let root = try DataExporter.writePackage(
            records: rides.map(DataExporter.Record.init), info: .init(appVersion: "1.0", useMiles: false, zydCode: nil),
            options: .init(from: cutoff, rideList: true, sensorData: false, routes: false, detailedFiles: false), in: parent
        )
        let ridesCSV = try String(contentsOf: root.appendingPathComponent("rides.csv"), encoding: .utf8)
        XCTAssertEqual(ridesCSV.split(separator: "\n").count, expected + 1, "only rides inside the period")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("samples.csv").path), "sensor data was not chosen")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("routes").path).count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("rides").path).count, 0)
    }

    func testPackedDataIsLosslessSmallAndStillReadsOldRides() throws {
        let samples = (0..<1800).map { second -> RideSample in
            let t = Double(second)
            return RideSample(offset: t, speedKmh: 18.123456 + sin(t / 30), powerWatts: 240.7 + cos(t / 20) * 90, batteryPercent: 80 - second / 200, voltage: 40.123456 - t / 4000)
        }
        let plain = try JSONEncoder().encode(samples)
        let packed = try PackedData.pack(samples)
        XCTAssertLessThan(packed.count * 2, plain.count, "lossless compression should still save at least half")
        XCTAssertTrue(PackedData.isPacked(packed))
        XCTAssertFalse(PackedData.isPacked(plain))

        let decoded = try PackedData.decode([RideSample].self, from: packed)
        XCTAssertEqual(decoded, samples, "every value comes back exactly as recorded")

        let track = (0..<500).map { TrackPoint(latitude: 52.5200123456 + Double($0) * 0.0000123456, longitude: 13.4050987654 + sin(Double($0) / 9) * 0.0003, timestamp: Date(timeIntervalSinceReferenceDate: 782_000_000.123456 + Double($0))) }
        XCTAssertEqual(try PackedData.decode([TrackPoint].self, from: try PackedData.pack(track)), track)
        XCTAssertEqual(try PackedData.decode([RideSample].self, from: plain).count, samples.count, "old plain JSON still reads")
    }

    func testSamplesFromBeforeSensorsStillDecodeAndNewOnesRoundTrip() throws {
        let old = Data(#"[{"offset":1,"speedKmh":18.5,"powerWatts":200,"batteryPercent":80,"voltage":40.1}]"#.utf8)
        let decoded = try JSONDecoder().decode([RideSample].self, from: old)
        XCTAssertNil(decoded[0].controllerTemperature)
        XCTAssertNil(decoded[0].sensors)

        let sensors = PhoneSensors(altitudeMeters: 3.25, vibrationG: 0.0123456, peakG: 0.4, rotationDegPerSecond: 31.5)
        let sample = RideSample(offset: 2, speedKmh: 19, powerWatts: 210, batteryPercent: 80, voltage: 40, controllerTemperature: 37, motorTemperature: 41, sensors: sensors)
        XCTAssertEqual(try PackedData.decode([RideSample].self, from: try PackedData.pack([sample])), [sample])
    }

    func testOldRidesArePackedOnce() throws {
        let container = try ModelContainer(for: Ride.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let samples = (0..<300).map { RideSample(offset: Double($0), speedKmh: 15.25, powerWatts: 200, batteryPercent: 70, voltage: 39.5) }
        let ride = Ride(
            startedAt: .now.addingTimeInterval(-3600), endedAt: .now, distanceKm: 4, averageSpeedKmh: 15, maxSpeedKmh: 20,
            energyWh: 60, batteryStart: 80, batteryEnd: 74, maxControllerTemperature: 40, maxMotorTemperature: 45,
            internalResistanceOhm: nil, samplesData: try JSONEncoder().encode(samples), trackData: nil
        )
        context.insert(ride)
        try context.save()
        let before = ride.samplesData.count

        XCTAssertEqual(try StorageMaintenance.pack(in: context), 1)
        XCTAssertTrue(PackedData.isPacked(ride.samplesData))
        XCTAssertLessThan(ride.samplesData.count, before / 2)
        XCTAssertEqual(try PackedData.decode([RideSample].self, from: ride.samplesData), samples, "packing never changes a value")
        XCTAssertEqual(try StorageMaintenance.pack(in: context), 0, "already packed rides are left alone")
    }

    @MainActor
    func testLastBatteryIsRememberedAndShownWithoutAScooter() throws {
        BatteryReading.clear()
        defer { BatteryReading.clear() }
        let reading = BatteryReading(percent: 64, voltage: 38.4, date: Date(timeIntervalSinceReferenceDate: 800_000_000), current: 0.3)
        reading.save()
        XCTAssertEqual(BatteryReading.stored(), reading)
        let store = ScooterStore(link: MockScooter(behavior: .init(simulatesRide: false)))
        XCTAssertEqual(store.batteryPercent, 64, "last known level while nothing is connected")
        XCTAssertFalse(store.batteryIsLive)
        XCTAssertEqual(store.batteryDate, reading.date)
    }

    func testBatteryHistoryIsWorkedOutInOnePass() {
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)
        func entry(_ daysAgo: Double, km: Double, wh: Double, used: Int = 5, resistance: Double? = nil) -> BatteryHistory.Entry {
            .init(id: UUID(), startedAt: now.addingTimeInterval(-daysAgo * 86_400), distanceKm: km, energyWh: wh, batteryStart: 60, batteryEnd: 60 - used, internalResistanceOhm: resistance)
        }
        let entries = [entry(1, km: 4, wh: 80, resistance: 0.2), entry(10, km: 6, wh: 150, resistance: 0.4), entry(60, km: 10, wh: 200)]
        let history = BatteryHistory(entries: entries, now: now)
        XCTAssertEqual(history.rideCount, 3)
        XCTAssertEqual(history.totalDistanceKm, 20, accuracy: 1e-9)
        XCTAssertEqual(history.monthRides, 2, "the 60 day old ride is outside the last 30 days")
        XCTAssertEqual(history.monthEnergyWh, 230, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(history.consumption).current, 430.0 / 20, accuracy: 1e-9)
        XCTAssertEqual(history.efficiency.count, 3)
        XCTAssertLessThan(history.efficiency[0].date, history.efficiency[2].date, "oldest first for drawing")
        XCTAssertEqual(history.packResistanceOhm, 0.4, accuracy: 1e-9, "the median of the measured values")
        XCTAssertEqual(BatteryHistory(entries: []).packResistanceOhm, BatteryHistory.typicalResistanceOhm)
    }
}

