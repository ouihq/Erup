import XCTest
@testable import ScooterProtocol

final class WriteQueueTests: XCTestCase {
    func testKeepAlivesAreCoalesced() {
        var queue = WriteQueue()
        let keepAlive = WriteQueue.Item(channel: .data, bytes: SessionFrames.keepAlive, isKeepAlive: true)
        XCTAssertTrue(queue.enqueue(keepAlive))
        XCTAssertFalse(queue.enqueue(keepAlive))
        XCTAssertEqual(queue.count, 1)
    }

    func testControlFramesJumpAheadOfKeepAlive() {
        var queue = WriteQueue()
        queue.enqueue(.init(channel: .data, bytes: SessionFrames.keepAlive, isKeepAlive: true))
        queue.enqueue(.init(channel: .data, bytes: [1]))
        queue.enqueue(.init(channel: .command, bytes: [2]))
        XCTAssertEqual(queue.popFirst()?.bytes, [1])
        XCTAssertEqual(queue.popFirst()?.bytes, [2])
        XCTAssertEqual(queue.popFirst()?.isKeepAlive, true)
        XCTAssertNil(queue.popFirst())
    }

    func testRemoveAll() {
        var queue = WriteQueue()
        queue.enqueue(.init(channel: .data, bytes: [1]))
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
    }
}
