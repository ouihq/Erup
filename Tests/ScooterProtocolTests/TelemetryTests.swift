import XCTest
@testable import ScooterProtocol

final class TelemetryTests: XCTestCase {
    func testFrame1CaptureVector() throws {
        let t = try Telemetry1(parsing: Capture.frame1)
        XCTAssertEqual(t.gear, .sport)
        XCTAssertEqual(t.batteryPercent, 98)
        XCTAssertEqual(t.speedKmh(scaled: false), 0.1, accuracy: 1e-9)
        XCTAssertEqual(t.voltage, 41.2, accuracy: 1e-9)
        XCTAssertEqual(t.current, 0, accuracy: 1e-9)
        XCTAssertEqual(t.controllerTemperature, 22)
        XCTAssertEqual(t.motorTemperature, 22)
        XCTAssertEqual(t.tripKm, 0.0, accuracy: 1e-9)
        XCTAssertEqual(t.totalKm, 2.4, accuracy: 1e-9)
        XCTAssertEqual(t.register0.rawValue, 0x0c02)
        XCTAssertTrue(t.register0.lockFlag)
        XCTAssertFalse(t.register0.headlight)
        XCTAssertEqual(t.register0.gearBits, 2)
    }

    func testFrame2CaptureVector() throws {
        let t = try Telemetry2(parsing: Capture.frame2)
        XCTAssertEqual(t.limitCruise, 3)
        XCTAssertEqual(t.caps, SpeedCaps(eco: 6, comfort: 12, sport: 21))
        XCTAssertFalse(t.speedScalingFlag)
        XCTAssertNil(t.displayModel)
        XCTAssertNil(t.displayFirmware)
    }

    func testSpeedUsesLargerCopyAndScalingFlag() throws {
        let bytes = FrameEncoder.telemetry1(
            gear: 1, batteryPercent: 50, speedRaw: 0, voltageDeci: 400, currentRaw: 0,
            controllerTemperature: 20, motorTemperature: 20, tripDeci: 0, totalDeci: 0, register0: 0
        )
        var mutated = Array(bytes.dropLast(2))
        mutated[6] = 0x13; mutated[7] = 0x88
        mutated[8] = 0x00; mutated[9] = 0x00
        let t = try Telemetry1(parsing: CRC16.appending(to: mutated))
        XCTAssertEqual(t.speedKmh(scaled: false), 5.0, accuracy: 1e-9)
        XCTAssertEqual(t.speedKmh(scaled: true), 500.0, accuracy: 1e-9)
    }

    func testSignedCurrentAndTemperature() throws {
        let bytes = FrameEncoder.telemetry1(
            gear: 0, batteryPercent: 80, speedRaw: 0, voltageDeci: 410, currentRaw: -128,
            controllerTemperature: -5, motorTemperature: 40, tripDeci: 123, totalDeci: 70_000, register0: 0
        )
        let t = try Telemetry1(parsing: bytes)
        XCTAssertEqual(t.current, -2.0, accuracy: 1e-9)
        XCTAssertEqual(t.controllerTemperature, -5)
        XCTAssertEqual(t.tripKm, 12.3, accuracy: 1e-9)
        XCTAssertEqual(t.totalKm, 7000.0, accuracy: 1e-9)
    }

    func testFrame2ScalingFlagAndDisplayInfo() throws {
        let bytes = FrameEncoder.telemetry2(
            limitCruise: 3, caps: SpeedCaps(eco: 6, comfort: 12, sport: 21),
            flags: 1 << 12, displayModel: 0x1234, displayFirmware: (1, 2, 3)
        )
        let t = try Telemetry2(parsing: bytes)
        XCTAssertTrue(t.speedScalingFlag)
        XCTAssertEqual(t.displayModel, 0x1234)
        XCTAssertEqual(t.displayFirmware, "V1.2.3")
    }

    func testEncoderReproducesCapture() {
        let f1 = FrameEncoder.telemetry1(
            gear: 2, batteryPercent: 98, speedRaw: 100, voltageDeci: 412, currentRaw: 0,
            controllerTemperature: 22, motorTemperature: 22, tripDeci: 0, totalDeci: 24, register0: 0x0c02
        )
        XCTAssertEqual(f1, Capture.frame1)
        let f2 = FrameEncoder.telemetry2(
            limitCruise: 3, caps: SpeedCaps(eco: 6, comfort: 12, sport: 21), flags: 0x0100
        )
        XCTAssertEqual(f2, Capture.frame2)
    }

    func testParsingRejectsBadInput() {
        XCTAssertThrowsError(try Telemetry1(parsing: Array(Capture.frame1.dropLast()))) {
            XCTAssertEqual($0 as? ProtocolError, .wrongLength(expected: 25, actual: 24))
        }
        var badCRC = Capture.frame1
        badCRC[24] ^= 0xFF
        XCTAssertThrowsError(try Telemetry1(parsing: badCRC)) {
            XCTAssertEqual($0 as? ProtocolError, .badCRC)
        }
        XCTAssertThrowsError(try Telemetry2(parsing: Capture.frame1)) {
            XCTAssertEqual($0 as? ProtocolError, .badHeader)
        }
    }

    func testRegisterBitAccessors() {
        let register = ControllerRegister(rawValue: 0b1000_1010_0110_0101)
        XCTAssertEqual(register.gearBits, 1)
        XCTAssertTrue(register.headlight)
        XCTAssertTrue(register.bootMode)
        XCTAssertTrue(register.imperialUnits)
        XCTAssertTrue(register.cruiseControl)
        XCTAssertTrue(register.lockFlag)
        XCTAssertTrue(register.ambientLight)
        XCTAssertEqual(register.unknownBits, 0)
        XCTAssertEqual(ControllerRegister(rawValue: 0x0010).unknownBits, 0x0010)
    }
}
