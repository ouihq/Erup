import Foundation
import ScooterAnalytics
import UniformTypeIdentifiers

extension UTType {
    /// The file Erup writes a backup to. Declared in Info.plist, so Files shows it as an Erup backup and opens it in Erup.
    static let erupBackup = UTType(exportedAs: "me.ouihq.erup.backup", conformingTo: .data)
}

/// Everything Erup can put back: the rides with their sensor samples and routes, and the settings. The PIN and the
/// paired scooter stay on the phone they belong to.
struct BackupArchive: Codable, Sendable {
    static let kind = "erup-backup"
    static let currentFormat = 1

    var kind = BackupArchive.kind
    var format = BackupArchive.currentFormat
    var createdAt: Date
    var app: String
    var rides: [RideRecord]
    var settings: [String: SettingValue]
}

/// One ride as a plain value, independent of how the app stores it, so a backup stays readable by later versions.
struct RideRecord: Codable, Sendable, Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var distanceKm: Double
    var averageSpeedKmh: Double
    var maxSpeedKmh: Double
    var energyWh: Double
    var batteryStart: Int
    var batteryEnd: Int
    var maxControllerTemperature: Int
    var maxMotorTemperature: Int
    var internalResistanceOhm: Double?
    var regenWh: Double?
    var samples: [RideSample]
    var track: [TrackPoint]
}

/// A stored setting. Only plain values are kept, so a backup can never carry anything but preferences.
enum SettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    init?(_ object: Any) {
        if CFGetTypeID(object as CFTypeRef) == CFBooleanGetTypeID(), let value = object as? Bool {
            self = .bool(value)
        } else if let value = object as? Int {
            self = .int(value)
        } else if let value = object as? Double {
            self = .double(value)
        } else if let value = object as? String {
            self = .string(value)
        } else {
            return nil
        }
    }

    var object: Any {
        switch self {
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        }
    }
}

enum BackupError: LocalizedError, Equatable {
    case unreadable
    case newerFormat(Int)
    case noFolder
    case folderUnavailable
    case nothingInFolder
    case notDownloaded

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file is not an Erup backup, or it is damaged."
        case .newerFormat: "This backup was made by a newer version of Erup. Update Erup, then try again."
        case .noFolder: "Choose a backup folder first."
        case .folderUnavailable: "The backup folder can't be reached. Choose it again."
        case .nothingInFolder: "There is no backup in the folder yet."
        case .notDownloaded: "The backup is still downloading from iCloud. Try again in a moment."
        }
    }
}
