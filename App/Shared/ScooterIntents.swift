import AppIntents
import Foundation

enum GearOption: String, AppEnum {
    case eco, comfort, sport

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Gear"
    static let caseDisplayRepresentations: [GearOption: DisplayRepresentation] = [
        .eco: "Eco", .comfort: "Drive", .sport: "Sport",
    ]

    var raw: UInt8 {
        switch self {
        case .eco: 0
        case .comfort: 1
        case .sport: 2
        }
    }
}

struct SetHeadlightIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set scooter headlight"

    @Parameter(title: "Headlight on")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ScooterCommandCenter.shared.run(.headlight(value))
        return .result()
    }
}

struct SetLockIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set scooter lock"

    @Parameter(title: "Locked")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ScooterCommandCenter.shared.run(.locked(value))
        return .result()
    }
}

struct TurnOnLightIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn on scooter light"

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ScooterCommandCenter.shared.run(.headlight(true))
        return .result()
    }
}

struct LockScooterIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock scooter"

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ScooterCommandCenter.shared.run(.locked(true))
        return .result()
    }
}

struct SetGearIntent: AppIntent {
    static let title: LocalizedStringResource = "Set scooter gear"

    @Parameter(title: "Gear")
    var gear: GearOption

    init() {}

    init(gear: GearOption) {
        self.gear = gear
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await ScooterCommandCenter.shared.run(.gear(gear.raw))
        return .result()
    }
}

struct ScooterBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Scooter battery"

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let snapshot = SnapshotStore.load(), let percent = snapshot.batteryPercent else {
            throw BatteryError.unknown
        }
        let age = snapshot.lastSeen.map { $0.formatted(.relative(presentation: .named)) } ?? "at an unknown time"
        let range = snapshot.rangeKm.map { ", about \(Int($0.rounded())) kilometres of range" } ?? ""
        return .result(value: percent, dialog: "The scooter battery is at \(percent) percent\(range). Last seen \(age).")
    }

    enum BatteryError: Error, CustomLocalizedStringResourceConvertible {
        case unknown

        var localizedStringResource: LocalizedStringResource {
            "Erup has not seen the scooter yet."
        }
    }
}
