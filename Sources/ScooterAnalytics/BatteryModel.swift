import Foundation

/// Battery mathematics for the Pure Flex pack: 10 lithium-ion cells in series, 36 V nominal, 9.5 Ah (342 Wh),
/// charged with 42 V at 2.0 A (manual, section 5.6).
public enum BatteryModel {
    public static let cellsInSeries = 10.0
    public static let nominalVoltage = 36.0
    public static let nominalAmpHours = 9.5
    public static let nominalCapacityWh = nominalVoltage * nominalAmpHours
    public static let chargerWatts = 42.0 * 2.0
    /// Share of the charger's power that ends up in the battery, before the slow end of the charge.
    public static let chargeEfficiency = 0.9

    /// Open-circuit voltage per cell against state of charge, for a typical NMC cell. The curve is flat in the
    /// middle, so a voltage reading is accurate to a few percent at best there and much better near full and empty.
    private static let cellCurve: [(volts: Double, percent: Double)] = [
        (3.27, 0), (3.61, 5), (3.69, 10), (3.71, 15), (3.73, 20), (3.75, 25), (3.77, 30), (3.79, 35), (3.80, 40),
        (3.82, 45), (3.84, 50), (3.85, 55), (3.87, 60), (3.91, 65), (3.95, 70), (3.98, 75), (4.02, 80), (4.08, 85),
        (4.11, 90), (4.15, 95), (4.20, 100),
    ]

    /// What the pack would read with no load: terminal voltage plus the drop across the internal resistance.
    /// `current` is positive while discharging.
    public static func openCircuitVoltage(terminal: Double, current: Double, resistanceOhm: Double) -> Double {
        terminal + current * resistanceOhm
    }

    /// State of charge in percent, from the open-circuit voltage of the whole pack.
    public static func stateOfCharge(openCircuitVoltage: Double) -> Double {
        let perCell = openCircuitVoltage / cellsInSeries
        guard let first = cellCurve.first, let last = cellCurve.last else { return 0 }
        if perCell <= first.volts { return 0 }
        if perCell >= last.volts { return 100 }
        for (low, high) in zip(cellCurve, cellCurve.dropFirst()) where perCell <= high.volts {
            return low.percent + (perCell - low.volts) / (high.volts - low.volts) * (high.percent - low.percent)
        }
        return 100
    }

    /// Learned capacity against the nominal one, as a percentage. Above 100 is possible for a fresh pack.
    public static func stateOfHealth(capacityWh: Double) -> Double {
        capacityWh / nominalCapacityWh * 100
    }

    /// Hours until full. `measuredWatts` is the power seen while charging; without it the charger rating is used.
    /// The last part of a lithium-ion charge tapers off, so the time is stretched by a share of the remaining energy.
    public static func hoursToFull(percent: Double, capacityWh: Double, measuredWatts: Double? = nil) -> Double {
        let missing = max(0, min(100, 100 - percent)) / 100
        let watts = max(measuredWatts ?? chargerWatts * chargeEfficiency, 1)
        let taper = 1 + 0.25 * min(1, missing * 2)
        return capacityWh * missing / watts * taper
    }
}
