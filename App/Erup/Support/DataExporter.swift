import Foundation
import ScooterAnalytics

/// Writes every ride, with its sensor samples and route, as a folder of plain files and zips it for sharing.
/// Nothing secret is exported: the PIN and Keychain contents are never included.
enum DataExporter {
    struct Info {
        var appVersion: String
        var useMiles: Bool
        var zydCode: String?
        var exportedAt: Date = .now
    }

    /// What to export and for which period.
    struct Options: Equatable, Sendable {
        var from: Date?
        var to: Date?
        /// `rides.csv`: one row per ride.
        var rideList = true
        /// `samples.csv`: speed, power, battery and voltage over time for every ride. The largest part by far.
        var sensorData = true
        /// `routes/*.gpx`: the recorded route of each ride.
        var routes = true
        /// `rides/*.json`: everything about one ride in a single file.
        var detailedFiles = false

        func includes(_ date: Date) -> Bool {
            (from.map { date >= $0 } ?? true) && (to.map { date <= $0 } ?? true)
        }

        var isEmpty: Bool { !rideList && !sensorData && !routes && !detailedFiles }
    }

    /// A plain copy of a ride, so the heavy work can run off the main actor.
    struct Record: Sendable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date
        let duration: TimeInterval
        let distanceKm: Double
        let averageSpeedKmh: Double
        let maxSpeedKmh: Double
        let energyWh: Double
        let batteryStart: Int
        let batteryEnd: Int
        let maxControllerTemperature: Int
        let maxMotorTemperature: Int
        let internalResistanceOhm: Double?
        let samplesData: Data
        let trackData: Data?

        init(_ ride: Ride) {
            id = ride.id
            startedAt = ride.startedAt
            endedAt = ride.endedAt
            duration = ride.duration
            distanceKm = ride.distanceKm
            averageSpeedKmh = ride.averageSpeedKmh
            maxSpeedKmh = ride.maxSpeedKmh
            energyWh = ride.energyWh
            batteryStart = ride.batteryStart
            batteryEnd = ride.batteryEnd
            maxControllerTemperature = ride.maxControllerTemperature
            maxMotorTemperature = ride.maxMotorTemperature
            internalResistanceOhm = ride.internalResistanceOhm
            samplesData = ride.samplesData
            trackData = ride.trackData
        }
    }

    private struct ExportedRide: Encodable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date
        let durationSeconds: Double
        let distanceKm: Double
        let averageSpeedKmh: Double
        let maxSpeedKmh: Double
        let energyWh: Double
        let batteryStartPercent: Int
        let batteryEndPercent: Int
        let maxControllerTemperatureC: Int
        let maxMotorTemperatureC: Int
        let internalResistanceOhm: Double?
        let samples: [Sample]
        let route: [Point]

        struct Sample: Encodable {
            let offsetSeconds: Double
            let speedKmh: Double
            let powerWatts: Double
            let batteryPercent: Int
            let voltage: Double
        }

        struct Point: Encodable {
            let latitude: Double
            let longitude: Double
            let time: Date
        }
    }

    private struct Summary: Encodable {
        struct Totals: Encodable {
            let rides: Int
            let distanceKm: Double
            let durationSeconds: Double
            let topSpeedKmh: Double
            let energyWh: Double
        }

        let exportedAt: Date
        let from: Date?
        let to: Date?
        let app: String
        let usesMiles: Bool
        let zydCode: String?
        let totals: Totals
        let files: [String]
    }

    // MARK: Package

    /// Creates the package folder inside `parent` and returns it. Rows are written to the files as they are
    /// produced, so memory stays flat however many rides there are.
    @discardableResult
    static func writePackage(records: [Record], info: Info, options: Options = Options(), in parent: URL) throws -> URL {
        let stamp = info.exportedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let root = parent.appendingPathComponent("Erup-Export-\(stamp)", isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: root.appendingPathComponent("rides"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("routes"), withIntermediateDirectories: true)

        let ordered = records.filter { options.includes($0.startedAt) }.sorted { $0.startedAt < $1.startedAt }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let ridesFile = try options.rideList ? CSVFile(
            url: root.appendingPathComponent("rides.csv"),
            header: "id,started_at,ended_at,duration_s,distance_km,average_speed_kmh,max_speed_kmh,energy_wh,battery_start_pct,battery_end_pct,max_controller_temp_c,max_motor_temp_c,internal_resistance_ohm,has_route"
        ) : nil
        let samplesFile = try options.sensorData
            ? CSVFile(url: root.appendingPathComponent("samples.csv"), header: "ride_id,offset_s,time,speed_kmh,power_w,battery_pct,voltage_v")
            : nil
        var files = ["README.txt", "summary.json"]
        if options.rideList { files.append("rides.csv") }
        if options.sensorData { files.append("samples.csv") }

        for record in ordered {
            try autoreleasepool {
                let wantsSamples = options.sensorData || options.detailedFiles
                let wantsTrack = options.routes || options.detailedFiles || options.rideList
                let samples = wantsSamples ? ((try? PackedData.decode([RideSample].self, from: record.samplesData)) ?? []) : []
                let track = wantsTrack ? (record.trackData.flatMap { try? PackedData.decode([TrackPoint].self, from: $0) } ?? []) : []
                let id = record.id.uuidString

                try ridesFile?.append([[
                    id, iso(record.startedAt), iso(record.endedAt), number(record.duration), number(record.distanceKm),
                    number(record.averageSpeedKmh), number(record.maxSpeedKmh), number(record.energyWh),
                    "\(record.batteryStart)", "\(record.batteryEnd)", "\(record.maxControllerTemperature)",
                    "\(record.maxMotorTemperature)", record.internalResistanceOhm.map(number) ?? "", track.isEmpty ? "no" : "yes",
                ].joined(separator: ",")])
                try samplesFile?.append(options.sensorData ? samples.map { sample in
                    [
                        id, number(sample.offset), iso(record.startedAt.addingTimeInterval(sample.offset)),
                        number(sample.speedKmh), number(sample.powerWatts), "\(sample.batteryPercent)", number(sample.voltage),
                    ].joined(separator: ",")
                } : [])

                let name = "\(fileStamp(record.startedAt))-\(id.prefix(8))"
                if options.detailedFiles {
                    let exported = ExportedRide(
                        id: record.id, startedAt: record.startedAt, endedAt: record.endedAt, durationSeconds: record.duration,
                        distanceKm: record.distanceKm, averageSpeedKmh: record.averageSpeedKmh, maxSpeedKmh: record.maxSpeedKmh,
                        energyWh: record.energyWh, batteryStartPercent: record.batteryStart, batteryEndPercent: record.batteryEnd,
                        maxControllerTemperatureC: record.maxControllerTemperature, maxMotorTemperatureC: record.maxMotorTemperature,
                        internalResistanceOhm: record.internalResistanceOhm,
                        samples: samples.map { .init(offsetSeconds: $0.offset, speedKmh: $0.speedKmh, powerWatts: $0.powerWatts, batteryPercent: $0.batteryPercent, voltage: $0.voltage) },
                        route: track.map { .init(latitude: $0.latitude, longitude: $0.longitude, time: $0.timestamp) }
                    )
                    try encoder.encode(exported).write(to: root.appendingPathComponent("rides/\(name).json"))
                    files.append("rides/\(name).json")
                }
                if options.routes, !track.isEmpty {
                    try gpx(track, name: name).write(to: root.appendingPathComponent("routes/\(name).gpx"), atomically: true, encoding: .utf8)
                    files.append("routes/\(name).gpx")
                }
            }
        }
        try ridesFile?.close()
        try samplesFile?.close()

        let summary = Summary(
            exportedAt: info.exportedAt, from: options.from, to: options.to, app: info.appVersion, usesMiles: info.useMiles, zydCode: info.zydCode,
            totals: .init(
                rides: ordered.count,
                distanceKm: ordered.reduce(0) { $0 + $1.distanceKm },
                durationSeconds: ordered.reduce(0) { $0 + $1.duration },
                topSpeedKmh: ordered.map(\.maxSpeedKmh).max() ?? 0,
                energyWh: ordered.reduce(0) { $0 + $1.energyWh }
            ),
            files: files
        )
        try encoder.encode(summary).write(to: root.appendingPathComponent("summary.json"))
        try readme.write(to: root.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        return root
    }

    /// Builds the package in a temporary folder and returns a zip file ready to share.
    static func makeArchive(records: [Record], info: Info, options: Options = Options()) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("erup-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let package = try writePackage(records: records, info: info, options: options, in: work)
        return try zip(package)
    }

    /// A CSV file that is written a block of lines at a time.
    private final class CSVFile {
        private let handle: FileHandle

        init(url: URL, header: String) throws {
            FileManager.default.createFile(atPath: url.path, contents: Data((header + "\n").utf8))
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        }

        func append(_ lines: [String]) throws {
            guard !lines.isEmpty else { return }
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        }

        func close() throws {
            try handle.close()
        }
    }

    static func zip(_ directory: URL) throws -> URL {
        var coordinationError: NSError?
        var outcome: Result<URL, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { zipped in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(directory.lastPathComponent + ".zip")
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zipped, to: destination)
                outcome = .success(destination)
            } catch {
                outcome = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        return try outcome.get()
    }

    // MARK: Formatting

    private static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private static func fileStamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted))
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func gpx(_ track: [TrackPoint], name: String) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="Erup" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "<trk><name>\(name)</name><trkseg>",
        ]
        for point in track {
            lines.append(#"<trkpt lat="\#(point.latitude)" lon="\#(point.longitude)"><time>\#(iso(point.timestamp))</time></trkpt>"#)
        }
        lines.append("</trkseg></trk></gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static let readme = """
    Erup data export

    summary.json   Totals, the period that was exported and the list of files in this package.
    rides.csv      One row per ride: distance, speeds, energy, battery, temperatures. (If chosen.)
    samples.csv    The sensor samples of every ride: speed, power, battery percent and voltage over time. (If chosen.)
    rides/         One JSON file per ride with the same values plus its samples and route. (If chosen.)
    routes/        One GPX file per ride that recorded a route. (If chosen.)

    Distances are in kilometres, speeds in km/h, power in watts, voltage in volts, temperatures in degrees Celsius.
    Times are ISO 8601. The scooter PIN and other secrets are never part of an export.
    """
}
