/// Builds scooter-to-phone frames. Used by the mock scooter and tests; the app never sends these.
public enum FrameEncoder {
    public static func telemetry1(
        gear: UInt8,
        batteryPercent: UInt8,
        speedRaw: UInt16,
        voltageDeci: UInt16,
        currentRaw: Int16,
        controllerTemperature: Int8,
        motorTemperature: Int8,
        tripDeci: UInt16,
        totalDeci: UInt32,
        register0: UInt16
    ) -> [UInt8] {
        var frame: [UInt8] = [0xAB, 0x00, 0x19, 0x01, gear, batteryPercent]
        frame += be16(speedRaw) + be16(speedRaw)
        frame += be16(voltageDeci)
        frame += be16(UInt16(bitPattern: currentRaw))
        frame += [UInt8(bitPattern: controllerTemperature), UInt8(bitPattern: motorTemperature)]
        frame += be16(tripDeci)
        frame += [UInt8(totalDeci >> 16 & 0xFF), UInt8(totalDeci >> 8 & 0xFF), UInt8(totalDeci & 0xFF)]
        frame += be16(register0)
        return CRC16.appending(to: frame)
    }

    public static func telemetry2(
        limitCruise: UInt8,
        caps: SpeedCaps,
        flags: UInt16,
        displayModel: UInt16 = 0,
        displayFirmware: (UInt8, UInt8, UInt8) = (0, 0, 0)
    ) -> [UInt8] {
        var frame: [UInt8] = [0xAB, 0x01, 0x19, limitCruise, caps.eco, caps.comfort, caps.sport]
        frame += [0, 0, 0]
        frame += be16(flags)
        frame += [UInt8](repeating: 0, count: 6)
        frame += be16(displayModel)
        frame += [displayFirmware.0, displayFirmware.1, displayFirmware.2]
        return CRC16.appending(to: frame)
    }

    private static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }
}
