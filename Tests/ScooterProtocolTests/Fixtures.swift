import XCTest
@testable import ScooterProtocol

func hex(_ string: String) -> [UInt8] {
    let digits = string.filter { !$0.isWhitespace }
    precondition(digits.count % 2 == 0, "odd number of hex digits")
    var bytes: [UInt8] = []
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        bytes.append(UInt8(digits[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}

enum Capture {
    static let frame1 = hex("ab 00 19 01 02 62 00 64 00 64 01 9c 00 00 16 16 00 00 00 00 18 0c 02 06 df")
    static let frame2 = hex("ab 01 19 03 06 0c 15 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 c3 fe")
    static let sportLightsOff = hex("ab 00 0a 82 03 06 0c 15 57 fe")
    static let ecoHeadlight = hex("ab 00 0a 84 03 06 0c 15 df fe")
    static let comfort = hex("ab 00 0a 81 03 06 0c 15 13 fe")
    static let sportCruise = hex("ab 00 0a 92 03 06 0c 15 96 3d")

    static func context(speedKmh: Double = 0, register: UInt16 = 0x0c02) throws -> ControlContext {
        ControlContext(
            register0: ControllerRegister(rawValue: register),
            telemetry2: try Telemetry2(parsing: frame2),
            speedKmh: speedKmh
        )
    }
}
