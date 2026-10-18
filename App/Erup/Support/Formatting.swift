import Foundation
import ScooterProtocol

struct Units: Equatable {
    var useMiles: Bool

    static let kilometresPerMile = 1.609344

    var speedLabel: String { useMiles ? "mph" : "km/h" }
    var distanceLabel: String { useMiles ? "mi" : "km" }

    func speed(fromKmh kmh: Double) -> Double { useMiles ? kmh / Self.kilometresPerMile : kmh }
    func distance(fromKm km: Double) -> Double { useMiles ? km / Self.kilometresPerMile : km }
    func perDistance(_ perKm: Double) -> Double { useMiles ? perKm * Self.kilometresPerMile : perKm }
}

extension Array where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

extension Gear {
    var title: String {
        switch self {
        case .eco: "Eco"
        case .comfort: "Drive"
        case .sport: "Sport"
        }
    }
}

extension ControlChange {
    enum Kind: Hashable {
        case gear, headlight, cruiseControl, lockFlag, imperialUnits
    }

    var kind: Kind {
        switch self {
        case .gear: .gear
        case .headlight: .headlight
        case .cruiseControl: .cruiseControl
        case .lockFlag: .lockFlag
        case .imperialUnits: .imperialUnits
        }
    }
}
