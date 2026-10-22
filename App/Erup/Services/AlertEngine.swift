import Foundation

struct AlertEngine {
    enum Alert: Equatable {
        case batteryLow(Int)
        case batteryCritical(Int)
        case controllerHot(Int)
        case motorHot(Int)
        case chargeComplete
    }

    struct Reading {
        var batteryPercent: Int
        var controllerTemperature: Int
        var motorTemperature: Int
        var current: Double
        var speedKmh: Double
        var isConnected: Bool
        var date: Date
    }

    /// Where each alert fires. Nil switches that alert off. The defaults are conservative guesses, not manufacturer limits.
    struct Limits: Equatable {
        var batteryLow: Int?
        var batteryCritical: Int?
        var controllerHot: Int?
        var motorHot: Int?
        var chargeComplete: Bool

        static let standard = Limits(batteryLow: 20, batteryCritical: 10, controllerHot: 70, motorHot: 90, chargeComplete: true)
        /// How far a reading must move back before the same alert can fire again.
        static let batteryRearm = 5
        static let temperatureRearm = 10
        static let chargingCurrent = -0.2
        static let chargingDuration: TimeInterval = 30
        static let fullBattery = 100

        /// What the rider chose in Settings.
        static var current: Limits { AlertSettings.limits }
    }

    private var lowArmed = true
    private var criticalArmed = true
    private var controllerArmed = true
    private var motorArmed = true
    private var chargeArmed = true
    private var chargingSince: Date?

    mutating func evaluate(_ reading: Reading, limits: Limits = .current) -> [Alert] {
        guard reading.isConnected else {
            chargingSince = nil
            return []
        }
        var alerts: [Alert] = []

        if let critical = limits.batteryCritical, reading.batteryPercent <= critical, criticalArmed {
            criticalArmed = false
            lowArmed = false
            alerts.append(.batteryCritical(reading.batteryPercent))
        } else if let low = limits.batteryLow, reading.batteryPercent <= low, lowArmed {
            lowArmed = false
            alerts.append(.batteryLow(reading.batteryPercent))
        }
        if reading.batteryPercent >= (limits.batteryCritical ?? 0) + Limits.batteryRearm { criticalArmed = true }
        if reading.batteryPercent >= (limits.batteryLow ?? 0) + Limits.batteryRearm { lowArmed = true }

        if let hot = limits.controllerHot, reading.controllerTemperature >= hot, controllerArmed {
            controllerArmed = false
            alerts.append(.controllerHot(reading.controllerTemperature))
        } else if reading.controllerTemperature < (limits.controllerHot ?? 0) - Limits.temperatureRearm {
            controllerArmed = true
        }
        if let hot = limits.motorHot, reading.motorTemperature >= hot, motorArmed {
            motorArmed = false
            alerts.append(.motorHot(reading.motorTemperature))
        } else if reading.motorTemperature < (limits.motorHot ?? 0) - Limits.temperatureRearm {
            motorArmed = true
        }

        let isCharging = reading.current <= Limits.chargingCurrent && reading.speedKmh < 0.5
        if isCharging {
            chargingSince = chargingSince ?? reading.date
        } else if reading.current > 0 {
            chargingSince = nil
        }
        if limits.chargeComplete, let chargingSince, chargeArmed, reading.batteryPercent >= Limits.fullBattery,
           reading.date.timeIntervalSince(chargingSince) >= Limits.chargingDuration {
            chargeArmed = false
            alerts.append(.chargeComplete)
        }
        if reading.batteryPercent < 95 { chargeArmed = true }
        return alerts
    }
}
