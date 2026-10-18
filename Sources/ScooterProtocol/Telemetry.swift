public struct SpeedCaps: Equatable, Sendable {
    public let eco: UInt8
    public let comfort: UInt8
    public let sport: UInt8

    public init(eco: UInt8, comfort: UInt8, sport: UInt8) {
        self.eco = eco
        self.comfort = comfort
        self.sport = sport
    }
}

public struct Telemetry1: Equatable, Sendable {
    public static let length = 25

    public let gearRaw: UInt8
    public let batteryPercent: Int
    public let speedRaw: UInt16
    public let voltage: Double
    public let current: Double
    public let controllerTemperature: Int
    public let motorTemperature: Int
    public let tripKm: Double
    public let totalKm: Double
    public let register0: ControllerRegister
    public let raw: [UInt8]

    public var gear: Gear? { Gear(rawValue: gearRaw) }
    public var power: Double { voltage * current }

    public func speedKmh(scaled: Bool) -> Double {
        Double(speedRaw) / 1000 * (scaled ? 100 : 1)
    }

    public init(parsing frame: [UInt8]) throws {
        guard frame.count == Self.length else {
            throw ProtocolError.wrongLength(expected: Self.length, actual: frame.count)
        }
        guard frame[0] == 0xAB, frame[1] == 0x00, frame[2] == 0x19 else {
            throw ProtocolError.badHeader
        }
        guard CRC16.isValid(frame) else { throw ProtocolError.badCRC }

        gearRaw = frame[4]
        batteryPercent = Int(frame[5])
        speedRaw = max(frame.uint16(at: 6), frame.uint16(at: 8))
        voltage = Double(frame.uint16(at: 10)) / 10
        current = Double(frame.int16(at: 12)) / 64
        controllerTemperature = Int(Int8(bitPattern: frame[14]))
        motorTemperature = Int(Int8(bitPattern: frame[15]))
        tripKm = Double(frame.uint16(at: 16)) / 10
        totalKm = Double(frame.uint24(at: 18)) / 10
        register0 = ControllerRegister(rawValue: frame.uint16(at: 21))
        raw = frame
    }
}

public struct Telemetry2: Equatable, Sendable {
    public static let length = 25
    public static let speedScalingBit = 12

    public let limitCruise: UInt8
    public let caps: SpeedCaps
    public let flags: UInt16
    public let displayModel: UInt16?
    public let displayFirmware: String?
    public let raw: [UInt8]

    public var speedScalingFlag: Bool { flags & (1 << UInt16(Self.speedScalingBit)) != 0 }

    public init(parsing frame: [UInt8]) throws {
        guard frame.count == Self.length else {
            throw ProtocolError.wrongLength(expected: Self.length, actual: frame.count)
        }
        guard frame[0] == 0xAB, frame[1] == 0x01, frame[2] == 0x19 else {
            throw ProtocolError.badHeader
        }
        guard CRC16.isValid(frame) else { throw ProtocolError.badCRC }

        limitCruise = frame[3]
        caps = SpeedCaps(eco: frame[4], comfort: frame[5], sport: frame[6])
        flags = frame.uint16(at: 10)
        let model = frame.uint16(at: 18)
        displayModel = model == 0 ? nil : model
        displayFirmware = model == 0 ? nil : "V\(frame[20]).\(frame[21]).\(frame[22])"
        raw = frame
    }
}
