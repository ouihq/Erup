import XCTest
@testable import Erup

final class BridgeLeaseTests: XCTestCase {
    func testOnlyOneExchangeCanHoldTheBridge() {
        var lease = BridgeLease()
        XCTAssertNotNil(lease.acquire())
        XCTAssertTrue(lease.isActive)
        XCTAssertNil(lease.acquire(), "a second exchange must wait or fail as busy")
    }

    func testOwnerReleasesAndTheBridgeIsFreeAgain() {
        var lease = BridgeLease()
        let owner = lease.acquire()
        XCTAssertTrue(lease.release(owner: owner))
        XCTAssertFalse(lease.isActive)
        XCTAssertNotNil(lease.acquire())
    }

    func testStaleOwnerCannotCloseANewerExchange() {
        // iOS suspended the first exchange; the watchdog released it and a second one started.
        var lease = BridgeLease()
        let stale = lease.acquire()
        lease.release(owner: stale)
        let current = lease.acquire()

        XCTAssertFalse(lease.release(owner: stale), "the late finisher must not close the current exchange")
        XCTAssertTrue(lease.isActive)
        XCTAssertEqual(lease.owner, current)
    }

    func testReleaseWithoutOwnerClearsAnyHolder() {
        var lease = BridgeLease()
        _ = lease.acquire()
        XCTAssertTrue(lease.release(), "a dropped connection clears the bridge whoever held it")
        XCTAssertFalse(lease.isActive)
        XCTAssertFalse(lease.release(), "releasing a free bridge does nothing")
    }
}

@MainActor
final class ForegroundRefreshTests: XCTestCase {
    private func waitUntil(_ description: String, timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while await !condition() {
            if ContinuousClock.now > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testComingBackToTheForegroundReadsTheLockStateAgain() async throws {
        let mock = MockScooter(behavior: .init(confirmsWrites: true, simulatesRide: false))
        let store = ScooterStore(link: mock)
        await store.start()
        try await waitUntil("store ready") { store.isReady }
        try await waitUntil("first control word read") { await mock.controlWordReads >= 1 && store.controlWord != nil }
        let before = await mock.controlWordReads

        store.refreshAfterForeground()

        try await waitUntil("a second control word read") { await mock.controlWordReads > before }
    }

    func testForegroundRefreshDoesNothingWithoutAConnection() async throws {
        let mock = MockScooter(behavior: .init(simulatesRide: false, startsPaired: false))
        let store = ScooterStore(link: mock)
        await store.start()

        store.refreshAfterForeground()
        try await Task.sleep(for: .milliseconds(500))

        let reads = await mock.controlWordReads
        XCTAssertEqual(reads, 0)
    }
}
