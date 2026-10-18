public struct ControllerRegister: Equatable, Hashable, Sendable {
    public enum Bit {
        public static let headlight = 2
        public static let bootMode = 5
        public static let imperialUnits = 6
        public static let cruiseControl = 9
        public static let lock = 11
        public static let ambientLight = 15
    }

    public static let knownMask: UInt16 =
        0x0003
        | 1 << UInt16(Bit.headlight)
        | 1 << UInt16(Bit.bootMode)
        | 1 << UInt16(Bit.imperialUnits)
        | 1 << UInt16(Bit.cruiseControl)
        | 1 << UInt16(Bit.lock)
        | 1 << UInt16(Bit.ambientLight)

    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public var gearBits: UInt8 { UInt8(rawValue & 0x3) }
    public var gear: Gear? { Gear(rawValue: gearBits) }
    public var headlight: Bool { bit(Bit.headlight) }
    public var bootMode: Bool { bit(Bit.bootMode) }
    public var imperialUnits: Bool { bit(Bit.imperialUnits) }
    public var cruiseControl: Bool { bit(Bit.cruiseControl) }
    public var lockFlag: Bool { bit(Bit.lock) }
    public var ambientLight: Bool { bit(Bit.ambientLight) }
    public var unknownBits: UInt16 { rawValue & ~Self.knownMask }

    public func bit(_ index: Int) -> Bool {
        rawValue & (1 << UInt16(index)) != 0
    }

    public func applying(_ change: ControlChange) -> ControllerRegister {
        var copy = self
        switch change {
        case .gear(let gear): copy.rawValue = (rawValue & ~0x3) | UInt16(gear.rawValue)
        case .headlight(let on): copy.set(Bit.headlight, on)
        case .cruiseControl(let on): copy.set(Bit.cruiseControl, on)
        case .lockFlag(let on): copy.set(Bit.lock, on)
        case .imperialUnits(let on): copy.set(Bit.imperialUnits, on)
        }
        return copy
    }

    private mutating func set(_ index: Int, _ value: Bool) {
        if value {
            rawValue |= 1 << UInt16(index)
        } else {
            rawValue &= ~(1 << UInt16(index))
        }
    }
}
