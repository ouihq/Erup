public enum ControlChange: Equatable, Sendable {
    case gear(Gear)
    case headlight(Bool)
    case cruiseControl(Bool)
    case lockFlag(Bool)
    case imperialUnits(Bool)

    public var requiresStandstill: Bool {
        switch self {
        case .lockFlag, .cruiseControl: true
        case .gear, .headlight, .imperialUnits: false
        }
    }

    public func isReflected(in register: ControllerRegister) -> Bool {
        switch self {
        case .gear(let gear): register.gearBits == gear.rawValue
        case .headlight(let on): register.headlight == on
        case .cruiseControl(let on): register.cruiseControl == on
        case .lockFlag(let on): register.lockFlag == on
        case .imperialUnits(let on): register.imperialUnits == on
        }
    }
}

public struct ControlContext: Sendable {
    public let register0: ControllerRegister
    public let telemetry2: Telemetry2
    public let speedKmh: Double

    public init(register0: ControllerRegister, telemetry2: Telemetry2, speedKmh: Double) {
        self.register0 = register0
        self.telemetry2 = telemetry2
        self.speedKmh = speedKmh
    }

    public init(telemetry1: Telemetry1, telemetry2: Telemetry2) {
        self.init(
            register0: telemetry1.register0,
            telemetry2: telemetry2,
            speedKmh: telemetry1.speedKmh(scaled: telemetry2.speedScalingFlag)
        )
    }
}

public enum ControlFrame {
    public static let length = 10
    public static let standstillThresholdKmh = 1.0

    private enum CtrlBit {
        static let headlight: UInt8 = 1 << 2
        static let ambientLight: UInt8 = 1 << 3
        static let cruiseControl: UInt8 = 1 << 4
        static let bootMode: UInt8 = 1 << 5
        static let imperialUnits: UInt8 = 1 << 6
        static let lock: UInt8 = 1 << 7
    }

    public static func make(_ change: ControlChange, context: ControlContext) throws -> [UInt8] {
        if change.requiresStandstill, context.speedKmh > standstillThresholdKmh {
            throw ProtocolError.refusedWhileMoving(change, speedKmh: context.speedKmh)
        }
        let register = context.register0.applying(change)
        let caps = context.telemetry2.caps
        let payload: [UInt8] = [
            0xAB, 0x00, 0x0A,
            controlByte(for: register),
            context.telemetry2.limitCruise,
            caps.eco, caps.comfort, caps.sport,
        ]
        return CRC16.appending(to: payload)
    }

    static func controlByte(for register: ControllerRegister) -> UInt8 {
        var ctrl = register.gearBits
        if register.headlight { ctrl |= CtrlBit.headlight }
        if register.ambientLight { ctrl |= CtrlBit.ambientLight }
        if register.cruiseControl { ctrl |= CtrlBit.cruiseControl }
        if register.bootMode { ctrl |= CtrlBit.bootMode }
        if register.imperialUnits { ctrl |= CtrlBit.imperialUnits }
        if register.lockFlag { ctrl |= CtrlBit.lock }
        return ctrl
    }
}
