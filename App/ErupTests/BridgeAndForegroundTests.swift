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

final class KeepAliveGateTests: XCTestCase {
    func testKeepAlivesAreAllowedUntilABridgeExchangeIsClosed() {
        let gate = KeepAliveGate()
        XCTAssertTrue(gate.allows(at: .now))
    }

    func testNoKeepAliveRightAfterLeavingTheBridge() {
        // A keep-alive straight after the leave frame killed the stream in 8 of 8 exchanges on a real scooter.
        var gate = KeepAliveGate()
        let left = ContinuousClock.now
        gate.holdAfterBridge(now: left)
        XCTAssertFalse(gate.allows(at: left))
        XCTAssertFalse(gate.allows(at: left + .milliseconds(100)))
        XCTAssertFalse(gate.allows(at: left + .milliseconds(399)))
    }

    func testKeepAlivesResumeAfterTheHold() {
        var gate = KeepAliveGate()
        let left = ContinuousClock.now
        gate.holdAfterBridge(now: left)
        XCTAssertTrue(gate.allows(at: left + .milliseconds(400)))
        XCTAssertTrue(gate.allows(at: left + .seconds(2)))
    }

    func testTheHoldCoversTheSilencePeriodThatWorkedOnARealScooter() {
        // 250 ms and 500 ms both resumed 12 of 12 times; the hold must be inside that range.
        XCTAssertGreaterThanOrEqual(KeepAliveGate.holdAfterLeavingBridge, .milliseconds(250))
        XCTAssertLessThanOrEqual(KeepAliveGate.holdAfterLeavingBridge, .milliseconds(500))
    }

    func testANewSessionStartsWithoutAHold() {
        var gate = KeepAliveGate()
        gate.holdAfterBridge(now: .now)
        gate.reset()
        XCTAssertTrue(gate.allows(at: .now))
    }
}

final class StreamStallPolicyTests: XCTestCase {
    func testNothingHappensWhileFramesKeepArriving() {
        var policy = StreamStallPolicy()
        XCTAssertEqual(policy.evaluate(silentFor: .milliseconds(300)), .none)
        XCTAssertEqual(policy.evaluate(silentFor: .milliseconds(3900)), .none)
    }

    func testAStallFirstTriesAKeepAliveBurstThatKeepsTheLinkUp() {
        // A reconnect makes the scooter beep, so it is only the fallback.
        var policy = StreamStallPolicy()
        XCTAssertEqual(policy.evaluate(silentFor: .seconds(4)), .sendKeepAlives)
        XCTAssertTrue(policy.isRecovering)
    }

    func testReconnectsOnlyWhenTheKeepAliveBurstDidNotHelp() {
        var policy = StreamStallPolicy()
        XCTAssertEqual(policy.evaluate(silentFor: .seconds(4)), .sendKeepAlives)
        XCTAssertEqual(policy.evaluate(silentFor: .seconds(5)), .none, "the keep-alive burst gets a moment to work")
        XCTAssertEqual(policy.evaluate(silentFor: .seconds(6)), .reconnect)
    }

    func testOnlyOneReconnectIsRequestedPerStall() {
        var policy = StreamStallPolicy()
        let actions = [4, 5, 6, 8, 9, 12].map { policy.evaluate(silentFor: .seconds($0)) }
        XCTAssertEqual(actions, [.sendKeepAlives, .none, .reconnect, .none, .none, .none])
    }

    func testFramesReturningStartsTheNextStallFromScratch() {
        var policy = StreamStallPolicy()
        XCTAssertEqual(policy.evaluate(silentFor: .seconds(4)), .sendKeepAlives)
        policy.reset()
        XCTAssertFalse(policy.isRecovering)
        XCTAssertEqual(policy.evaluate(silentFor: .seconds(4)), .sendKeepAlives)
    }

    func testAfterABridgeExchangeTheStreamIsExpectedBackWithinTwoSeconds() {
        var policy = StreamStallPolicy()
        XCTAssertEqual(policy.evaluate(silentFor: .milliseconds(1900), afterBridge: true), .none)
        XCTAssertEqual(policy.evaluate(silentFor: .seconds(2), afterBridge: true), .sendKeepAlives)
        XCTAssertEqual(policy.evaluate(silentFor: .seconds(4), afterBridge: true), .reconnect)
        XCTAssertTrue(StreamStallPolicy().showsAsSilent(silentFor: .seconds(2), afterBridge: true))
        XCTAssertFalse(StreamStallPolicy().showsAsSilent(silentFor: .seconds(2)), "without a bridge exchange four seconds are allowed")
    }

    func testAStalledLinkIsShownAsLostFromFourSeconds() {
        let policy = StreamStallPolicy()
        XCTAssertFalse(policy.showsAsSilent(silentFor: .seconds(3)))
        XCTAssertTrue(policy.showsAsSilent(silentFor: .seconds(4)))
    }
}

@MainActor
final class BackgroundBridgeGatingTests: XCTestCase {
    func testLockStateIsNotReadWhileTheAppIsInTheBackground() async throws {
        let mock = MockScooter(behavior: .init(confirmsWrites: true, simulatesRide: false))
        let store = ScooterStore(link: mock)
        store.isInForeground = false
        await store.start()

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !store.isReady {
            if ContinuousClock.now > deadline { return XCTFail("store never became ready") }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(1000))

        let reads = await mock.controlWordReads
        XCTAssertEqual(reads, 0, "a bridge exchange in the background can be suspended halfway and swallow telemetry")
    }
}
