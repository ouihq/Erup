import ScooterProtocol
import XCTest
@testable import Erup

@MainActor
final class ScooterStoreTests: XCTestCase {
    private func makeStore(_ behavior: MockScooter.Behavior) async throws -> ScooterStore {
        let store = ScooterStore(link: MockScooter(behavior: behavior))
        await store.start()
        try await waitUntil("store ready") { store.isReady }
        return store
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testLiveHistoryIsSampledOncePerSecondAndBounded() async throws {
        let store = try await makeStore(.init(confirmsWrites: true, simulatesRide: false))
        try await waitUntil("two samples") { store.liveHistory.count >= 2 }
        let dates = store.liveHistory.map(\.date)
        for (earlier, later) in zip(dates, dates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), 1)
        }
        XCTAssertLessThanOrEqual(store.liveHistory.count, Int(ScooterStore.liveHistoryWindow) + 1)
        XCTAssertGreaterThan(Date().timeIntervalSince(store.liveHistory[0].date), -1)
    }

    func testAppearanceSettingMapsToColorScheme() {
        XCTAssertNil(AppearanceSetting.system.colorScheme)
        XCTAssertEqual(AppearanceSetting.light.colorScheme, .light)
        XCTAssertEqual(AppearanceSetting.dark.colorScheme, .dark)
    }

    func testChangeIsAppliedOptimisticallyThenConfirmed() async throws {
        let store = try await makeStore(.init(confirmsWrites: true, simulatesRide: false))
        XCTAssertFalse(store.headlightOn)

        store.setHeadlight(true)
        XCTAssertTrue(store.headlightOn)
        XCTAssertFalse(store.pendingChanges.isEmpty)

        try await waitUntil("confirmation") { store.pendingChanges.isEmpty }
        XCTAssertTrue(store.headlightOn)
        XCTAssertNil(store.alertMessage)
    }

    func testUnconfirmedChangeRollsBackAndSurfacesAnError() async throws {
        let store = try await makeStore(.init(confirmsWrites: false, simulatesRide: false))

        store.setHeadlight(true)
        XCTAssertTrue(store.headlightOn)

        try await waitUntil("rollback", timeout: .seconds(3)) { store.pendingChanges.isEmpty }
        XCTAssertFalse(store.headlightOn)
        XCTAssertNotNil(store.alertMessage)
    }

    func testGearChangeDoesNotDropAnEarlierPendingToggle() async throws {
        let store = try await makeStore(.init(confirmsWrites: true, simulatesRide: false))

        store.setHeadlight(true)
        store.setGear(.eco)
        try await waitUntil("both confirmed") { store.pendingChanges.isEmpty }

        XCTAssertTrue(store.headlightOn)
        XCTAssertEqual(store.gear, .eco)
    }

    func testLockAndUnlockRoundTripOnTheDemoScooter() async throws {
        let store = try await makeStore(.init(confirmsWrites: true, simulatesRide: false))
        XCTAssertFalse(store.isLocked)
        XCTAssertTrue(store.telemetry1?.register0.lockFlag ?? false, "default polarity: a set bit means unlocked")

        store.setLocked(true)
        XCTAssertTrue(store.isLocked, "optimistic state shows locked immediately")
        try await waitUntil("lock confirmed") { store.pendingChanges.isEmpty }
        XCTAssertTrue(store.isLocked)
        XCTAssertFalse((store.controlWord ?? 0) & (1 << UInt16(ControllerRegister.Bit.lock)) != 0, "the scooter echoed the cleared bit in register 0")
        XCTAssertNil(store.alertMessage)

        store.setLocked(false)
        try await waitUntil("unlock confirmed") { store.pendingChanges.isEmpty }
        XCTAssertFalse(store.isLocked)
        XCTAssertTrue((store.controlWord ?? 0) & (1 << UInt16(ControllerRegister.Bit.lock)) != 0)
    }

    func testLockStillWorksWhenAPINIsAlreadyEnabled() async throws {
        let store = try await makeStore(.init(confirmsWrites: true, simulatesRide: false))
        await store.setPINEnabled(true)
        XCTAssertEqual(store.settings.pinEnabled, true)

        PINVault.pin = nil
        store.setLocked(true)
        XCTAssertNotNil(store.alertMessage, "without a saved PIN the lock is refused with an explanation")
        XCTAssertTrue(store.pendingChanges.isEmpty)
        store.dismissAlert()

        PINVault.pin = "888888"
        defer { PINVault.pin = nil }
        store.setLocked(true)
        try await waitUntil("lock confirmed with PIN on") { store.pendingChanges.isEmpty }
        XCTAssertTrue(store.isLocked)
        XCTAssertNil(store.alertMessage)

        store.setLocked(false)
        try await waitUntil("unlock confirmed with PIN on") { store.pendingChanges.isEmpty }
        XCTAssertFalse(store.isLocked)
    }

    func testLockIsRefusedWhileMoving() {
        let store = ScooterStore.preview(speedRaw: 18_400)
        store.setLocked(true)
        XCTAssertNotNil(store.alertMessage)
        XCTAssertTrue(store.pendingChanges.isEmpty)
        XCTAssertFalse(store.isLocked)
    }

    func testLockPolarityFlagFlipsTheWireBit() async throws {
        UserDefaults.standard.set(true, forKey: FeatureFlags.lockFlagMeansLockedKey)
        defer { UserDefaults.standard.removeObject(forKey: FeatureFlags.lockFlagMeansLockedKey) }
        let store = try await makeStore(.init(confirmsWrites: true, simulatesRide: false))
        // The mock starts with bit 11 set, which this polarity reads as already locked.
        XCTAssertTrue(store.isLocked)

        store.setLocked(false)
        try await waitUntil("unlock confirmed") { store.pendingChanges.isEmpty }
        XCTAssertFalse(store.isLocked)
        XCTAssertFalse((store.controlWord ?? 0) & (1 << UInt16(ControllerRegister.Bit.lock)) != 0)
    }

    func testCruiseIsConfirmedFromTheControlWord() async throws {
        let store = try await makeStore(.init(confirmsWrites: true, simulatesRide: false))
        store.setCruise(true)
        try await waitUntil("cruise confirmed") { store.pendingChanges.isEmpty }
        XCTAssertNil(store.alertMessage)
        XCTAssertTrue(store.cruiseOn)
        XCTAssertNotNil(store.controlWord)
        store.setCruise(false)
        try await waitUntil("cruise off confirmed") { store.pendingChanges.isEmpty }
        XCTAssertFalse(store.cruiseOn)
    }

    func testSettingsAreCachedForTheNextLaunch() async throws {
        UserDefaults.standard.removeObject(forKey: "scooter.settings.cache")
        defer { UserDefaults.standard.removeObject(forKey: "scooter.settings.cache") }
        let store = try await makeStore(.init(confirmsWrites: true, simulatesRide: false))
        await store.refreshSettings()
        XCTAssertNotNil(store.settings.pinEnabled)
        let cached = ScooterSettings.cached()
        XCTAssertEqual(cached.pinEnabled, store.settings.pinEnabled)
        XCTAssertEqual(cached.deviceDescription, store.settings.deviceDescription)
    }

    func testCruiseIsRefusedWhileMoving() async throws {
        let store = ScooterStore.preview(speedRaw: 18_400)
        store.setCruise(true)
        XCTAssertNotNil(store.alertMessage)
        XCTAssertTrue(store.pendingChanges.isEmpty)
    }
}

@MainActor
final class SettingsAndInfoTests: XCTestCase {
    private func connectedStore() async throws -> ScooterStore {
        let store = ScooterStore(link: MockScooter(behavior: .init(simulatesRide: false)))
        await store.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !store.isReady {
            if ContinuousClock.now > deadline { XCTFail("store never became ready") ; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return store
    }

    func testRefreshSettingsParsesEveryQuery() async throws {
        let store = try await connectedStore()
        await store.refreshSettings()
        XCTAssertEqual(store.settings.pinEnabled, false)
        XCTAssertNotNil(store.settings.deviceDescription)
        XCTAssertTrue(store.settings.failures.isEmpty)
    }

    func testSettingChangeIsReflectedAfterAcknowledgement() async throws {
        let store = try await connectedStore()
        await store.setPINEnabled(true)
        XCTAssertEqual(store.settings.pinEnabled, true)
    }

    func testInvalidPINIsRejectedBeforeSending() async throws {
        let store = try await connectedStore()
        let changed = await store.changePIN(from: "888888", to: "12")
        XCTAssertFalse(changed)
        XCTAssertNotNil(store.alertMessage)
    }

    func testChangingThePINNeedsTheCurrentPIN() async throws {
        let store = try await connectedStore()
        PINVault.pin = nil
        let changed = await store.changePIN(from: "111111", to: "654321")
        XCTAssertFalse(changed)
        XCTAssertNil(PINVault.pin, "a wrong old PIN must not be saved")
        XCTAssertNotNil(store.alertMessage)
    }

    func testChangingThePINVerifiesItAndStoresItInTheKeychain() async throws {
        let store = try await connectedStore()
        PINVault.pin = nil
        defer { PINVault.pin = nil }
        let changed = await store.changePIN(from: "888888", to: "654321")
        XCTAssertTrue(changed)
        XCTAssertEqual(PINVault.pin, "654321")
    }

    func testFrameLogNeverContainsPINs() async throws {
        let store = try await connectedStore()
        store.isFrameLoggingEnabled = true
        _ = await store.changePIN(from: "888888", to: "654321")
        PINVault.pin = nil
        let logged = store.frameLog.map { String(decoding: $0.bytes, as: UTF8.self) }.joined()
        XCTAssertFalse(logged.contains("888888"))
        XCTAssertFalse(logged.contains("654321"))
    }

    func testControllerInfoIsRefusedWhileMoving() async {
        let store = ScooterStore.preview(speedRaw: 12_000)
        await store.readControllerInfo()
        XCTAssertNil(store.controllerReadout)
        XCTAssertNotNil(store.alertMessage)
    }

    func testControllerInfoReadoutFromMock() async throws {
        let store = try await connectedStore()
        await store.readControllerInfo()
        XCTAssertEqual(store.controllerReadout?.info.firmware, "FW 4.2.7")
    }

    func testServiceReminder() {
        let reminder = ServiceReminder(intervalKm: 500, lastServiceKm: 100)
        XCTAssertEqual(reminder.remainingKm(totalKm: 400), 200)
        XCTAssertFalse(reminder.isDue(totalKm: 599))
        XCTAssertTrue(reminder.isDue(totalKm: 600))
    }
}
