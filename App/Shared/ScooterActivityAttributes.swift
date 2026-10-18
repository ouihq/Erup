import ActivityKit
import Foundation

struct ScooterActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var speedKmh: Int
        var batteryPercent: Int
        var rangeKm: Int?
        var gearRaw: UInt8
        var tripKm: Double
        var headlightOn: Bool
        var isConnected: Bool
        var usesMiles: Bool
    }

    var scooterName: String
}
