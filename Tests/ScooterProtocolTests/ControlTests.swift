import XCTest
@testable import ScooterProtocol

final class ControlTests: XCTestCase {
    func testCaptureVectors() throws {
        let context = try Capture.context()
        XCTAssertEqual(try ControlFrame.make(.headlight(false), context: context), Capture.sportLightsOff)
        XCTAssertEqual(try ControlFrame.make(.gear(.sport), context: context), Capture.sportLightsOff)

        let ecoLight = try ControlFrame.make(.headlight(true), context: try Capture.context(register: 0x0c00))
        XCTAssertEqual(ecoLight, Capture.ecoHeadlight)

        XCTAssertEqual(try ControlFrame.make(.gear(.comfort), context: context), Capture.comfort)
        XCTAssertEqual(try ControlFrame.make(.cruiseControl(true), context: context), Capture.sportCruise)
    }

    func testRegisterIsPreservedAcrossUnrelatedChange() throws {
        let register: UInt16 = 0x0c02 | 1 << 15 | 1 << 6
        let frame = try ControlFrame.make(.headlight(true), context: Capture.context(register: register))
        XCTAssertEqual(frame[3], 0b1100_1110)
    }

    func testEveryControlFrameEchoesCapsAndLimitCruiseUnchanged() throws {
        let telemetry2 = try Telemetry2(parsing: Capture.frame2)
        var changes: [ControlChange] = Gear.allCases.map { ControlChange.gear($0) }
        for on in [true, false] {
            changes.append(.headlight(on))
            changes.append(.cruiseControl(on))
            changes.append(.lockFlag(on))
            changes.append(.imperialUnits(on))
        }
        let registers: [UInt16] = [0x0000, 0x0c02, 0xFFFF, 0x8a65, 0x0800, 0x7FFF]

        for raw in registers {
            for change in changes {
                let context = ControlContext(
                    register0: ControllerRegister(rawValue: raw), telemetry2: telemetry2, speedKmh: 0
                )
                let frame = try ControlFrame.make(change, context: context)
                XCTAssertEqual(frame.count, ControlFrame.length)
                XCTAssertEqual(Array(frame[0...2]), [0xAB, 0x00, 0x0A])
                XCTAssertEqual(frame[4], telemetry2.limitCruise, "\(change) \(raw)")
                XCTAssertEqual(frame[5], telemetry2.caps.eco, "\(change) \(raw)")
                XCTAssertEqual(frame[6], telemetry2.caps.comfort, "\(change) \(raw)")
                XCTAssertEqual(frame[7], telemetry2.caps.sport, "\(change) \(raw)")
                XCTAssertTrue(CRC16.isValid(frame))
            }
        }
    }

    func testCapsFollowTheLatestFrame2() throws {
        let other = FrameEncoder.telemetry2(
            limitCruise: 9, caps: SpeedCaps(eco: 7, comfort: 14, sport: 25), flags: 0
        )
        let context = ControlContext(
            register0: ControllerRegister(rawValue: 0x0c02),
            telemetry2: try Telemetry2(parsing: other),
            speedKmh: 0
        )
        let frame = try ControlFrame.make(.headlight(true), context: context)
        XCTAssertEqual(Array(frame[4...7]), [9, 7, 14, 25])
    }

    /// Bytes captured from the original iOS app on a real scooter (lock, then unlock).
    func testControlWordFramesMatchTheOriginalApp() {
        XCTAssertEqual(BridgeFrames.readControlWordRequest, [0x01, 0x03, 0x00, 0x00, 0x00, 0x05, 0x85, 0xC9])
        XCTAssertEqual(BridgeFrames.writeControlWord(0x0A00), [0x01, 0x10, 0x00, 0x00, 0x00, 0x01, 0x02, 0x0A, 0x00, 0xA0, 0xF0])
        XCTAssertEqual(BridgeFrames.writeControlWord(0x0200), [0x01, 0x10, 0x00, 0x00, 0x00, 0x01, 0x02, 0x02, 0x00, 0xA7, 0x30])
    }

    func testBridgeDecoderReadsControlWordAndWriteAcknowledgement() {
        var decoder = BridgeReplyDecoder()
        let read = CRC16.appending(to: [0x01, 0x03, 0x00, 0x00, 0x0A, 0x0A, 0x00, 0, 0, 0, 0, 0, 0, 0, 0])
        let ack = CRC16.appending(to: [0x01, 0x10, 0x00, 0x00, 0x00, 0x01])
        let events = decoder.feed(read + ack)
        XCTAssertEqual(events, [
            .data(function: 0x03, address: 0, payload: [0x0A, 0x00, 0, 0, 0, 0, 0, 0, 0, 0]),
            .written(address: 0, wordCount: 1),
        ])
    }

    func testLockAndCruiseRefusedWhileMoving() throws {
        let moving = try Capture.context(speedKmh: 1.5)
        for change in [ControlChange.lockFlag(true), .lockFlag(false), .cruiseControl(true), .cruiseControl(false)] {
            XCTAssertThrowsError(try ControlFrame.make(change, context: moving)) {
                XCTAssertEqual($0 as? ProtocolError, .refusedWhileMoving(change, speedKmh: 1.5))
            }
        }
        XCTAssertNoThrow(try ControlFrame.make(.gear(.eco), context: moving))
        XCTAssertNoThrow(try ControlFrame.make(.headlight(true), context: moving))
    }

    func testStandstillBoundaryIsInclusive() throws {
        XCTAssertNoThrow(try ControlFrame.make(.lockFlag(true), context: Capture.context(speedKmh: 1.0)))
        XCTAssertThrowsError(try ControlFrame.make(.lockFlag(true), context: Capture.context(speedKmh: 1.01)))
    }

    func testConfirmationAgainstRegister() {
        let register = ControllerRegister(rawValue: 0x0c02)
        XCTAssertTrue(ControlChange.gear(.sport).isReflected(in: register))
        XCTAssertFalse(ControlChange.gear(.eco).isReflected(in: register))
        XCTAssertTrue(ControlChange.headlight(false).isReflected(in: register))
        XCTAssertFalse(ControlChange.headlight(true).isReflected(in: register))
    }

    func testSessionFramesAreTheDocumentedBytes() {
        XCTAssertEqual(SessionFrames.start, hex("a5 ff 00 00 00 00 00 5a"))
        XCTAssertEqual(SessionFrames.keepAlive, hex("a5 02 fd 5a"))
        XCTAssertEqual(SessionFrames.enterBridge, hex("a5 00 ff 00 00 00 00 5a"))
        XCTAssertEqual(SessionFrames.leaveBridge, SessionFrames.start)
    }
}
