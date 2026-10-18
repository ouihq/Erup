import Foundation

enum WidgetFormat {
    static let kilometresPerMile = 1.609344

    static func distance(_ km: Double?, usesMiles: Bool) -> String {
        guard let km else { return "–" }
        let value = usesMiles ? km / kilometresPerMile : km
        return "\(Int(value.rounded())) \(usesMiles ? "mi" : "km")"
    }

    static func gearName(_ raw: UInt8?) -> String {
        switch raw {
        case 0: "Eco"
        case 1: "Drive"
        case 2: "Sport"
        default: "–"
        }
    }
}
