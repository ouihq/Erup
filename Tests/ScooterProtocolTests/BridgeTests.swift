import XCTest
@testable import ScooterProtocol

final class BridgeTests: XCTestCase {
    func testReadRequestLayout() {
        XCTAssertEqual(BridgeFrames.controllerInfoRequests.count, 10)
        XCTAssertEqual(Array(BridgeFrames.controllerInfoRequests[9].prefix(6)), [0x01, 0x07, 0x00, 0x48, 0x00, 0x04])
        XCTAssertEqual(Array(BridgeFrames.batteryInfoRequest.prefix(6)), [0x01, 0x08, 0x00, 0x00, 0x00, 0x08])
        XCTAssertEqual(BridgeFrames.controllerInfoAddresses, [0, 8, 16, 24, 32, 40, 48, 56, 64, 72])
    }

    func testEveryBridgeRequestIsAReadWithAValidCRC() {
        for request in BridgeFrames.controllerInfoRequests + [BridgeFrames.batteryInfoRequest] {
            XCTAssertTrue(CRC16.isValid(request))
            XCTAssertEqual(request.count, 8)
            XCTAssertTrue([0x07, 0x08].contains(request[1]), "only read function codes may be sent")
            XCTAssertLessThanOrEqual(UInt16(request[2]) << 8 | UInt16(request[3]), 72)
        }
    }

    private func reply(address: UInt16, payload: [UInt8], function: UInt8 = 0x07) -> [UInt8] {
        CRC16.appending(to: [0x01, function, UInt8(address >> 8), UInt8(address & 0xFF), UInt8(payload.count)] + payload)
    }

    func testDecodesDataReplyAcrossFragments() {
        var decoder = BridgeReplyDecoder()
        let frame = reply(address: 8, payload: Array(1...8))
        var events = decoder.feed(Array(frame.prefix(6)))
        XCTAssertTrue(events.isEmpty)
        events = decoder.feed(Array(frame.dropFirst(6)))
        XCTAssertEqual(events, [.data(function: 0x07, address: 8, payload: Array(1...8))])
    }

    func testErrorReply() {
        var decoder = BridgeReplyDecoder()
        let error = CRC16.appending(to: [0x01, 0x87, 0x02])
        XCTAssertEqual(decoder.feed(error), [.failure(.bridgeError(function: 0x07, code: 0x02))])
    }

    func testResyncOverGarbageAndBadCRC() {
        var decoder = BridgeReplyDecoder()
        var bad = reply(address: 0, payload: Array(repeating: 0xAA, count: 8))
        bad[8] ^= 0xFF
        let good = reply(address: 8, payload: Array(repeating: 0xBB, count: 8))
        let events = decoder.feed([0x55, 0x66] + bad + good)
        XCTAssertEqual(events, [.data(function: 0x07, address: 8, payload: Array(repeating: 0xBB, count: 8))])
    }

    func testControllerInfoParsing() throws {
        func field(_ text: String) -> [UInt8] {
            let bytes = Array(text.utf8)
            return bytes + [UInt8](repeating: 0, count: 16 - bytes.count)
        }
        let info = try ControllerInfo(bytes: field("MODEL-X") + field("HW1.2") + field("BL3") + field("FW9.9.9") + field("0123456789ABCDEF"))
        XCTAssertEqual(info.model, "MODEL-X")
        XCTAssertEqual(info.hardware, "HW1.2")
        XCTAssertEqual(info.bootloader, "BL3")
        XCTAssertEqual(info.firmware, "FW9.9.9")
        XCTAssertEqual(info.uniqueCode, "0123456789ABCDEF")
        XCTAssertThrowsError(try ControllerInfo(bytes: [0, 1, 2])) {
            XCTAssertEqual($0 as? ProtocolError, .invalidControllerInfoLength(3))
        }
    }
}
