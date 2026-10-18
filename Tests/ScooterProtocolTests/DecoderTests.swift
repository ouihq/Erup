import XCTest
@testable import ScooterProtocol

final class DecoderTests: XCTestCase {
    func testSingleChunkYieldsBothFrames() {
        var decoder = TelemetryDecoder()
        let events = decoder.feed(Capture.frame1 + Capture.frame2)
        XCTAssertEqual(events.count, 2)
        guard case .telemetry1 = events[0], case .telemetry2 = events[1] else {
            return XCTFail("unexpected events \(events)")
        }
        XCTAssertEqual(decoder.droppedByteCount, 0)
    }

    func testByteByByteReassembly() {
        var decoder = TelemetryDecoder()
        var events: [TelemetryEvent] = []
        for byte in Capture.frame1 + Capture.frame2 {
            events += decoder.feed([byte])
        }
        XCTAssertEqual(events.count, 2)
    }

    func testTwentyByteMTUFragments() throws {
        var decoder = TelemetryDecoder()
        let stream = Capture.frame1 + Capture.frame2 + Capture.frame1
        var events: [TelemetryEvent] = []
        for start in stride(from: 0, to: stream.count, by: 20) {
            events += decoder.feed(Array(stream[start..<min(start + 20, stream.count)]))
        }
        XCTAssertEqual(events.count, 3)
    }

    func testLeadingGarbageIsDropped() {
        var decoder = TelemetryDecoder()
        let events = decoder.feed([0x00, 0x11, 0x22] + Capture.frame1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(decoder.droppedByteCount, 3)
    }

    func testResyncAfterCorruptedFrame() {
        var decoder = TelemetryDecoder()
        var corrupted = Capture.frame1
        corrupted[12] ^= 0xFF
        let events = decoder.feed(corrupted + Capture.frame2)
        XCTAssertEqual(events.count, 1)
        guard case .telemetry2 = events[0] else { return XCTFail("expected frame 2, got \(events)") }
        XCTAssertGreaterThanOrEqual(decoder.crcFailureCount, 1)
    }

    func testStrayHeaderByteInsideGarbageDoesNotStall() {
        var decoder = TelemetryDecoder()
        let events = decoder.feed([0xAB, 0xFF, 0xAB] + Capture.frame2)
        XCTAssertEqual(events.count, 1)
    }

    func testUnknownFrameTypeWithValidCRCIsSurfaced() {
        var decoder = TelemetryDecoder()
        let unknown = CRC16.appending(to: [0xAB, 0x07, 0x07, 0x01, 0x02])
        let events = decoder.feed(unknown)
        XCTAssertEqual(events, [.unknown(unknown)])
    }
}
