import Foundation

struct ServiceReminder: Equatable {
    static let intervalKey = "service.intervalKm"
    static let lastServiceKey = "service.lastServiceKm"
    static let defaultIntervalKm = 500.0

    var intervalKm: Double
    var lastServiceKm: Double

    func remainingKm(totalKm: Double) -> Double {
        lastServiceKm + intervalKm - totalKm
    }

    func isDue(totalKm: Double) -> Bool {
        remainingKm(totalKm: totalKm) <= 0
    }
}
