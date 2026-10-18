import XCTest
@testable import ScooterProtocol

final class CRCTests: XCTestCase {
    func testModbusCheckValue() {
        XCTAssertEqual(CRC16.modbus(Array("123456789".utf8)), 0x4B37)
    }

    func testCRCIsAppendedLowByteFirst() {
        let framed = CRC16.appending(to: [0xAB, 0x00, 0x0A, 0x82, 0x03, 0x06, 0x0C, 0x15])
        XCTAssertEqual(Array(framed.suffix(2)), [0x57, 0xFE])
    }

    func testValidityCheck() {
        XCTAssertTrue(CRC16.isValid(Capture.frame1))
        var corrupted = Capture.frame1
        corrupted[7] ^= 0x01
        XCTAssertFalse(CRC16.isValid(corrupted))
        XCTAssertFalse(CRC16.isValid([0x01, 0x02]))
    }
}
