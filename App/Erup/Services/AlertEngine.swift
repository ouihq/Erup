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

    /// Thresholds are conservative guesses, not manufacturer limits.
    enum Threshold {
        static let batteryLow = 20
        static let batteryLowRearm = 25
        static let batteryCritical = 10
        static let batteryCriticalRearm = 15
        static let controllerHot = 70
        static let controllerRearm = 60
        static let motorHot = 90
        static let motorRearm = 80
        static let chargingCurrent = -0.2
        static let chargingDuration: TimeInterval = 30
        static let fullBattery = 100
    }

    private var lowArmed = true
    private var criticalArmed = true
    private var controllerArmed = true
    private var motorArmed = true
    private var chargeArmed = true
    private var chargingSince: Date?

    mutating func evaluate(_ reading: Reading) -> [Alert] {
        guard reading.isConnected else {
            chargingSince = nil
            return []
        }
        var alerts: [Alert] = []

        if reading.batteryPercent <= Threshold.batteryCritical, criticalArmed {
            criticalArmed = false
            lowArmed = false
            alerts.append(.batteryCritical(reading.batteryPercent))
        } else if reading.batteryPercent <= Threshold.batteryLow, lowArmed {
            lowArmed = false
            alerts.append(.batteryLow(reading.batteryPercent))
        }
        if reading.batteryPercent >= Threshold.batteryCriticalRearm { criticalArmed = true }
        if reading.batteryPercent >= Threshold.batteryLowRearm { lowArmed = true }

        if reading.controllerTemperature >= Threshold.controllerHot, controllerArmed {
            controllerArmed = false
            alerts.append(.controllerHot(reading.controllerTemperature))
        } else if reading.controllerTemperature < Threshold.controllerRearm {
            controllerArmed = true
        }
        if reading.motorTemperature >= Threshold.motorHot, motorArmed {
            motorArmed = false
            alerts.append(.motorHot(reading.motorTemperature))
        } else if reading.motorTemperature < Threshold.motorRearm {
            motorArmed = true
        }

        let isCharging = reading.current <= Threshold.chargingCurrent && reading.speedKmh < 0.5
        if isCharging {
            chargingSince = chargingSince ?? reading.date
        } else if reading.current > 0 {
            chargingSince = nil
        }
        if let chargingSince, chargeArmed, reading.batteryPercent >= Threshold.fullBattery,
           reading.date.timeIntervalSince(chargingSince) >= Threshold.chargingDuration {
            chargeArmed = false
            alerts.append(.chargeComplete)
        }
        if reading.batteryPercent < 95 { chargeArmed = true }
        return alerts
    }
}
