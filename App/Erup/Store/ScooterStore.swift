import Foundation
import Observation
import ScooterAnalytics
import ScooterProtocol

struct ScooterSettings: Equatable, Codable {
    var pinEnabled: Bool?
    var deviceDescription: String?
    var failures: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case pinEnabled, deviceDescription
    }

    private static let cacheKey = "scooter.settings.cache"

    /// The last answers from the scooter, so Settings shows something at once while fresh ones load.
    static func cached() -> ScooterSettings {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let settings = try? JSONDecoder().decode(ScooterSettings.self, from: data) else { return ScooterSettings() }
        return settings
    }

    static func clearCache() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }

    func saveToCache() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.cacheKey) }
    }
}

/// The controller identification last read from the scooter, kept so it stays visible and exportable offline.
struct FirmwareRecord: Equatable, Codable {
    var model: String
    var hardware: String
    var bootloader: String
    var firmware: String
    var uniqueCode: String
    var readAt: Date

    private static let key = "scooter.firmware.record"

    init(_ info: ControllerInfo, readAt: Date = .now) {
        model = info.model
        hardware = info.hardware
        bootloader = info.bootloader
        firmware = info.firmware
        uniqueCode = info.uniqueCode
        self.readAt = readAt
    }

    static func stored() -> FirmwareRecord? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(FirmwareRecord.self, from: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// The battery as last seen from the scooter, so the app can still show it when the scooter is off or away.
struct BatteryReading: Equatable, Codable {
    var percent: Int
    var voltage: Double
    var date: Date
    /// Discharge current at that moment, positive while riding. Absent in readings saved before 1.3.
    var current: Double?

    private static let key = "scooter.lastBattery"

    static func stored() -> BatteryReading? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(BatteryReading.self, from: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// One entry in the notification center: an error from the app or an alert about the scooter.
struct Notice: Identifiable, Equatable {
    enum Kind: Equatable { case problem, alert }

    let id = UUID()
    let date: Date
    let message: String
    let kind: Kind
}

struct LiveSample: Identifiable, Equatable {
    let date: Date
    let speedKmh: Double
    let powerWatts: Double
    let voltage: Double
    let current: Double
    let batteryPercent: Int
    let controllerTemperature: Int
    let motorTemperature: Int

    var id: Date { date }
}

struct FrameLogEntry: Identifiable, Equatable {
    enum Direction: String { case rx = "RX", tx = "TX" }

    let id = UUID()
    let date: Date
    let direction: Direction
    let label: String
    let bytes: [UInt8]
}

@MainActor
@Observable
final class ScooterStore {
    private(set) var connection: ConnectionState = .unpaired
    private(set) var searchingSince: Date?
    private(set) var telemetry1: Telemetry1?
    private(set) var telemetry2: Telemetry2?
    private(set) var lastTelemetryDate: Date?
    private(set) var deviceInfo = DeviceInfo()
    private(set) var discovered: [DiscoveredScooter] = []
    private(set) var frameLog: [FrameLogEntry] = []
    private(set) var pendingChanges: [ControlChange.Kind: ControlChange] = [:]
    private(set) var alertMessage: String?
    /// Colours the banner. Nil for a problem, which is not about the scooter's level of anything.
    private(set) var alertSeverity: AlertSeverity?
    /// Everything that was reported, newest last. The banner is only a short-lived view of the latest entry.
    private(set) var notices: [Notice] = []
    private(set) var unreadNoticeCount = 0
    private(set) var settings = ScooterSettings.cached()
    private(set) var isLoadingSettings = false
    @ObservationIgnored private var settingsPrefetched = false
    /// Energy fed back into the battery while braking, since the scooter connected.
    private(set) var regenEnergyWh = 0.0
    /// Fastest speed seen since the scooter connected.
    private(set) var peakSpeedKmh = 0.0
    @ObservationIgnored private var regenAccumulator = 0.0
    @ObservationIgnored private var lastRegenDate: Date?
    private(set) var isRunningCommand = false
    private(set) var controllerReadout: ControllerReadout?
    private(set) var firmwareRecord = FirmwareRecord.stored()
    private(set) var lastBattery = BatteryReading.stored()
    private(set) var isReadingController = false
    var isFrameLoggingEnabled = false
    private(set) var rangeModel: RangeModel?
    private(set) var lastRide: ScooterSnapshot.RideSummary?
    private(set) var liveHistory: [LiveSample] = []

    @ObservationIgnored private let link: any ScooterLink
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var latestTelemetry1: Telemetry1?
    @ObservationIgnored private var lastPublish = ContinuousClock.now.advanced(by: .seconds(-1))
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshotEmit = ContinuousClock.now.advanced(by: .seconds(-10))
    @ObservationIgnored private var changeTokens: [ControlChange.Kind: UUID] = [:]
    /// Register 0 as read in bridge mode. The regular telemetry word follows the headlight and gear bits,
    /// but not the lock and cruise bits, so those two come from here.
    private(set) var controlWord: UInt16?
    @ObservationIgnored private var isReadingControlWord = false
    /// Bridge exchanges pause telemetry, and iOS can suspend the app in the middle of one, so the lock state
    /// is only read while the app is on screen.
    @ObservationIgnored var isInForeground = true
    @ObservationIgnored private var controlWordAttempts = 0
    @ObservationIgnored private var alertTask: Task<Void, Never>?
    @ObservationIgnored var onSample: (@MainActor (TelemetrySample) -> Void)?
    @ObservationIgnored var onRideContextInvalidated: (@MainActor () -> Void)?
    /// The app is leaving the foreground. Rides store what they have so far, because iOS may not give the app another turn.
    @ObservationIgnored var onBackground: (@MainActor () -> Void)?
    @ObservationIgnored var onForeground: (@MainActor () -> Void)?
    @ObservationIgnored private var lastFrameProcessed: Date?
    @ObservationIgnored private var lastBackgroundLog = Date.distantPast
    @ObservationIgnored var onSnapshot: (@MainActor (ScooterSnapshot) -> Void)?
    @ObservationIgnored private var atInbox: [ATReply] = []
    @ObservationIgnored private var unparsedReplies: [String] = []

    private static let publishInterval: Duration = .milliseconds(200)
    private static let snapshotInterval: Duration = .seconds(1)
    private static let confirmationWindow: Duration = .seconds(1)
    private static let alertDuration: Duration = .seconds(4)
    private static let noticeCapacity = 100
    private static let logCapacity = 300
    static let liveHistoryWindow: TimeInterval = 900
    private static let liveHistoryInterval: TimeInterval = 1

    init(link: any ScooterLink) {
        self.link = link
    }

    func start() async {
        guard eventTask == nil else { return }
        let events = link.events
        eventTask = Task {
            for await event in events {
                self.handle(event)
            }
        }
        await link.start()
    }

    // MARK: Derived state

    var isReady: Bool { connection.isConnected && latestTelemetry1 != nil && telemetry2 != nil }

    var effectiveRegister: ControllerRegister? {
        guard var register = telemetry1?.register0 else { return nil }
        register = overlaid(register)
        for change in pendingChanges.values { register = register.applying(change) }
        return register
    }

    private static let controlWordMask: UInt16 =
        1 << UInt16(ControllerRegister.Bit.lock) | 1 << UInt16(ControllerRegister.Bit.cruiseControl)

    private func overlaid(_ register: ControllerRegister) -> ControllerRegister {
        guard let controlWord else { return register }
        return ControllerRegister(rawValue: register.rawValue & ~Self.controlWordMask | controlWord & Self.controlWordMask)
    }

    /// Power flowing back into the battery right now. The controller reports it as negative current.
    /// The same rule the ride recorder and the ride detail use, so all of them show the same numbers.
    var regenWatts: Double { RegenDetection.recoveredWatts(powerWatts: telemetry1?.power ?? 0, speedKmh: speedKmh) }

    var speedKmh: Double {
        guard let telemetry1 else { return 0 }
        return telemetry1.speedKmh(scaled: telemetry2?.speedScalingFlag ?? false)
    }

    /// Full-scale value for the speedometer. A gear's speed is only what the scooter accelerates to; downhill it
    /// can go faster. So the dial has headroom above the sport limit and grows if a faster speed is seen.
    var speedometerMaxKmh: Double {
        let sport = telemetry2.map { Double($0.caps.sport) } ?? 0
        let limit = sport > 1 ? sport : 25
        let headroom = (limit * 1.3 / 5).rounded(.up) * 5
        return max(headroom, (peakSpeedKmh / 5).rounded(.up) * 5)
    }

    /// The speed the current gear accelerates to, shown as a mark on the speedometer.
    var gearLimitKmh: Double? {
        guard let caps = telemetry2?.caps, let gear else { return nil }
        let value: UInt8 = switch gear {
        case .eco: caps.eco
        case .comfort: caps.comfort
        case .sport: caps.sport
        }
        return value > 0 ? Double(value) : nil
    }

    /// The live battery level, or the last one seen when the scooter isn't sending.
    var batteryPercent: Int? {
        (telemetry1 ?? latestTelemetry1)?.batteryPercent ?? lastBattery?.percent
    }

    var batteryIsLive: Bool { connection.isConnected && (telemetry1 ?? latestTelemetry1) != nil }

    /// When the shown battery level was measured.
    var batteryDate: Date? { batteryIsLive ? Date() : (lastTelemetryDate ?? lastBattery?.date) }

    var rangeKm: Double? {
        guard let rangeModel, let percent = batteryPercent else { return nil }
        return rangeModel.rangeKm(batteryPercent: percent)
    }

    var rangeBandKm: ClosedRange<Double>? {
        guard let rangeModel, let percent = batteryPercent else { return nil }
        return rangeModel.rangeBandKm(batteryPercent: percent)
    }

    private func rememberBattery(from value: Telemetry1) {
        let now = Date()
        if let last = lastBattery, last.percent == value.batteryPercent, now.timeIntervalSince(last.date) < 60 { return }
        let reading = BatteryReading(percent: value.batteryPercent, voltage: value.voltage, date: now, current: value.current)
        lastBattery = reading
        reading.save()
    }

    func updateRideContext(rangeModel: RangeModel?, lastRide: ScooterSnapshot.RideSummary?) {
        self.rangeModel = rangeModel
        self.lastRide = lastRide
        emitSnapshot()
    }

    func invalidateRideContext() {
        onRideContextInvalidated?()
    }

    var gear: Gear? { effectiveRegister?.gear }
    var headlightOn: Bool { effectiveRegister?.headlight ?? false }
    var cruiseOn: Bool { effectiveRegister?.cruiseControl ?? false }

    var isLocked: Bool {
        guard let flag = effectiveRegister?.lockFlag else { return false }
        return FeatureFlags.lockFlagMeansLocked ? flag : !flag
    }

    // MARK: Pairing

    func beginPairing() async {
        discovered.removeAll()
        await link.beginPairingScan()
    }

    func endPairing() async {
        await link.endPairingScan()
    }

    func pair(with scooter: DiscoveredScooter) async {
        await link.pair(with: scooter.id)
    }

    func forgetScooter() async {
        await link.forget()
        latestTelemetry1 = nil
        telemetry1 = nil
        telemetry2 = nil
        pendingChanges.removeAll()
        changeTokens.removeAll()
        controlWord = nil
        controlWordAttempts = 0
        settingsPrefetched = false
        regenAccumulator = 0
        regenEnergyWh = 0
        peakSpeedKmh = 0
        lastRegenDate = nil
        settings = ScooterSettings()
        ScooterSettings.clearCache()
        controllerReadout = nil
        firmwareRecord = nil
        FirmwareRecord.clear()
        lastBattery = nil
        BatteryReading.clear()
        liveHistory.removeAll()
    }

    // MARK: Control

    func setGear(_ gear: Gear) { request(.gear(gear)) }
    func setHeadlight(_ on: Bool) { request(.headlight(on)) }
    func setCruise(_ on: Bool) { request(.cruiseControl(on)) }
    func setImperialUnits(_ on: Bool) { request(.imperialUnits(on)) }

    func setLocked(_ locked: Bool) {
        let flag = FeatureFlags.lockFlagMeansLocked ? locked : !locked
        request(.lockFlag(flag))
    }

    func report(_ message: String) {
        present(message)
    }

    func dismissAlert() {
        alertTask?.cancel()
        alertMessage = nil
        alertSeverity = nil
    }

    private func request(_ change: ControlChange) {
        DiagnosticLog.shared.log(.command, "requested \(change)")
        do {
            try submit(change)
        } catch {
            DiagnosticLog.shared.log(.command, "refused \(change): \(error.localizedDescription)")
            present(error.localizedDescription)
        }
    }

    private func submit(_ change: ControlChange) throws {
        guard connection.isConnected else { throw LinkFailure.notConnected }
        guard let telemetry1 = latestTelemetry1, let telemetry2 else { throw ProtocolError.telemetryNotReady }
        if case .lockFlag = change, settings.pinEnabled == true, PINVault.pin == nil {
            throw LinkFailure.commandRejected("This scooter needs its PIN to lock. Enter it under Settings → PIN used for lock.")
        }
        let speedKmh = telemetry1.speedKmh(scaled: telemetry2.speedScalingFlag)
        if case .lockFlag(let on) = change { return try submitLock(on, change: change, speedKmh: speedKmh) }
        var register = overlaid(telemetry1.register0)
        for pending in pendingChanges.values { register = register.applying(pending) }
        let context = ControlContext(register0: register, telemetry2: telemetry2, speedKmh: speedKmh)
        let frame = try ControlFrame.make(change, context: context)

        let kind = change.kind
        let token = UUID()
        pendingChanges[kind] = change
        changeTokens[kind] = token
        record(.tx, label: "control", bytes: frame)

        Task {
            do {
                try await self.link.write(frame)
            } catch {
                self.rollback(kind, token: token, message: error.localizedDescription)
                return
            }
            if kind == .cruiseControl {
                await self.confirmViaControlWord(change, token: token)
                return
            }
            do { try await Task.sleep(for: Self.confirmationWindow) } catch { return }
            self.rollback(kind, token: token, message: "The scooter did not confirm the change.")
        }
    }

    /// Lock is not an ordinary control frame. The scooter changes it only in bridge mode, after the PIN check,
    /// and it shows the result only in register 0, like the original app does.
    private func submitLock(_ on: Bool, change: ControlChange, speedKmh: Double) throws {
        if speedKmh > ControlFrame.standstillThresholdKmh {
            throw ProtocolError.refusedWhileMoving(change, speedKmh: speedKmh)
        }
        let kind = change.kind
        let token = UUID()
        pendingChanges[kind] = change
        changeTokens[kind] = token
        record(.tx, label: "lock \(on ? "bit set" : "bit clear")", bytes: [])

        Task {
            do {
                if let pin = PINVault.pin {
                    let reply = try await self.verifyPINRetryingOnce(pin)
                    guard reply.value == "Y" else {
                        throw LinkFailure.commandRejected("The scooter rejected the PIN. Check \"PIN used for lock\" in Settings.")
                    }
                }
                let word = try await self.link.lockControlWord(setLockBit: on)
                self.controlWord = word
                guard self.changeTokens[kind] == token else { return }
                let applied = ((word & (1 << UInt16(ControllerRegister.Bit.lock))) != 0) == on
                if applied {
                    self.pendingChanges[kind] = nil
                    self.changeTokens[kind] = nil
                    self.publish(force: true)
                } else {
                    self.rollback(kind, token: token, message: "The scooter did not confirm the change.")
                }
            } catch is CancellationError {
                return
            } catch {
                self.rollback(kind, token: token, message: error.localizedDescription)
            }
        }
    }

    /// A late answer is not a wrong PIN, so a timeout gets one more try. A rejected PIN is never retried.
    private func verifyPINRetryingOnce(_ pin: String) async throws -> ATReply {
        do {
            return try await perform(.verifyPIN(pin))
        } catch LinkFailure.timeout {
            try await Task.sleep(for: .milliseconds(300))
            return try await perform(.verifyPIN(pin))
        }
    }

    /// The scooter's telemetry never shows the cruise bit, so confirm it by reading register 0 in bridge mode.
    private func confirmViaControlWord(_ change: ControlChange, token: UUID) async {
        let kind = change.kind
        for _ in 0..<2 {
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard changeTokens[kind] == token else { return }
            do {
                let word = try await link.lockControlWord(setLockBit: nil)
                controlWord = word
                if change.isReflected(in: ControllerRegister(rawValue: word)) {
                    guard changeTokens[kind] == token else { return }
                    pendingChanges[kind] = nil
                    changeTokens[kind] = nil
                    publish(force: true)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
        rollback(kind, token: token, message: "The scooter did not confirm the change.")
    }

    private func accumulateRegen(power: Double, speedKmh: Double) {
        let now = Date()
        defer { lastRegenDate = now }
        let recovered = RegenDetection.recoveredWatts(powerWatts: power, speedKmh: speedKmh)
        guard let last = lastRegenDate, recovered > 0 else { return }
        regenAccumulator += recovered * min(now.timeIntervalSince(last), 1) / 3600
    }

    /// Loads the AT settings once per connection, so Settings is already filled when it opens.
    private func prefetchSettingsIfNeeded(speedKmh: Double) {
        // Not while riding: the extra writes load a link that was already struggling, and nobody reads settings mid-ride.
        guard !FeatureFlags.pauseAutomaticReads, !settingsPrefetched, !isLoadingSettings, isReady,
              speedKmh <= ControlFrame.standstillThresholdKmh else { return }
        settingsPrefetched = true
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            await self.refreshSettings()
        }
    }

    /// Reads the real lock and cruise state once per connection while the scooter stands still.
    private func refreshControlWordIfNeeded(speedKmh: Double, force: Bool = false) {
        guard isInForeground, force || (!FeatureFlags.pauseAutomaticReads && controlWord == nil && controlWordAttempts < 3), !isReadingControlWord,
              speedKmh <= ControlFrame.standstillThresholdKmh, pendingChanges.isEmpty else { return }
        isReadingControlWord = true
        if !force { controlWordAttempts += 1 }
        Task {
            defer { self.isReadingControlWord = false }
            if let word = try? await self.link.lockControlWord(setLockBit: nil) {
                DiagnosticLog.shared.log(.command, String(format: "control word read: 0x%04X", word))
                self.controlWord = word
                self.publish(force: true)
            }
        }
    }

    /// The lock and cruise bits are read once per connection, so after the app was in the background they
    /// can be stale. Read them again when the app comes back, while the scooter stands still.
    func appLeftForeground() {
        DiagnosticLog.shared.isForeground = false
        isInForeground = false
        onBackground?()
    }

    func refreshAfterForeground() {
        DiagnosticLog.shared.isForeground = true
        onForeground?()
        DiagnosticLog.shared.log(.app, "returned to the foreground: connection \(connection), last frame \(lastTelemetryDate.map { String(format: "%.1f s ago", Date().timeIntervalSince($0)) } ?? "never")")
        Task { await link.resumeAfterBackground() }
        guard connection.isConnected, let telemetry1 = latestTelemetry1, let telemetry2 else { return }
        refreshControlWordIfNeeded(speedKmh: telemetry1.speedKmh(scaled: telemetry2.speedScalingFlag), force: true)
    }

    /// Entry point for intents and queued commands. Waits for the link, submits, and waits for the register echo.
    func execute(_ command: ScooterCommand) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !isReady {
            if ContinuousClock.now > deadline { throw LinkFailure.notConnected }
            try await Task.sleep(for: .milliseconds(100))
        }
        let change: ControlChange
        switch command {
        case .headlight(let on):
            change = .headlight(on)
        case .locked(let locked):
            change = .lockFlag(FeatureFlags.lockFlagMeansLocked ? locked : !locked)
        case .gear(let raw):
            guard let gear = Gear(rawValue: raw) else { throw ProtocolError.badHeader }
            change = .gear(gear)
        }
        try submit(change)
        while pendingChanges[change.kind] != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let register = latestTelemetry1.map({ overlaid($0.register0) }), change.isReflected(in: register) else {
            throw CommandError.notConfirmed
        }
    }

    private func rollback(_ kind: ControlChange.Kind, token: UUID, message: String) {
        guard changeTokens[kind] == token else { return }
        DiagnosticLog.shared.log(.command, "rolled back \(kind): \(message)")
        changeTokens[kind] = nil
        pendingChanges[kind] = nil
        present(message)
    }

    private func confirmPendingChanges(against register: ControllerRegister) -> Bool {
        var confirmedAny = false
        for (kind, change) in pendingChanges where kind != .lockFlag && kind != .cruiseControl && change.isReflected(in: register) {
            DiagnosticLog.shared.log(.command, "confirmed \(kind) by the scooter")
            pendingChanges[kind] = nil
            changeTokens[kind] = nil
            confirmedAny = true
        }
        return confirmedAny
    }

    // MARK: Events

    private func handle(_ event: LinkEvent) {
        switch event {
        case .state(let state):
            connection = state
            if !connection.isConnected {
                controlWord = nil
                controlWordAttempts = 0
                settingsPrefetched = false
                lastRegenDate = nil
                peakSpeedKmh = 0
            }
            defer { emitSnapshot() }
            switch state {
            case .searching, .connecting:
                if searchingSince == nil { searchingSince = Date() }
            default:
                searchingSince = nil
            }
        case .telemetry(let telemetry):
            handle(telemetry)
        case .commandReply(let bytes):
            record(.rx, label: "AT", bytes: bytes)
            receiveReply(bytes)
        case .deviceInfo(let info):
            deviceInfo = info
        case .discovered(let scooter):
            if let index = discovered.firstIndex(where: { $0.id == scooter.id }) {
                discovered[index] = scooter
            } else {
                discovered.append(scooter)
            }
        case .failure(let failure):
            present(failure.localizedDescription)
        }
    }

    private func handle(_ event: TelemetryEvent) {
        switch event {
        case .telemetry1(let value):
            latestTelemetry1 = value
            lastTelemetryDate = Date()
            rememberBattery(from: value)
            noteBackgroundExecution()
            record(.rx, label: "frame 1", bytes: value.raw)
            onSample?(TelemetrySample(
                date: Date(),
                speedKmh: value.speedKmh(scaled: telemetry2?.speedScalingFlag ?? false),
                voltage: value.voltage,
                current: value.current,
                batteryPercent: value.batteryPercent,
                controllerTemperature: value.controllerTemperature,
                motorTemperature: value.motorTemperature
            ))
            appendLiveSample(for: value)
            refreshControlWordIfNeeded(speedKmh: value.speedKmh(scaled: telemetry2?.speedScalingFlag ?? false))
            accumulateRegen(power: value.power, speedKmh: value.speedKmh(scaled: telemetry2?.speedScalingFlag ?? false))
            prefetchSettingsIfNeeded(speedKmh: value.speedKmh(scaled: telemetry2?.speedScalingFlag ?? false))
            let confirmed = confirmPendingChanges(against: value.register0)
            publish(force: confirmed || telemetry1 == nil)
        case .telemetry2(let value):
            telemetry2 = value
            record(.rx, label: "frame 2", bytes: value.raw)
        case .unknown(let frame):
            record(.rx, label: "unknown", bytes: frame)
        case .rejected(let frame, let reason):
            record(.rx, label: "rejected: \(reason)", bytes: frame)
        }
    }

    /// While the app is in the background, records whether iOS is giving it time to run. A long gap between two
    /// frames the app processed means the app was suspended, which is what stops keep-alives and ride tracking.
    private func noteBackgroundExecution() {
        let now = Date()
        defer { lastFrameProcessed = now }
        guard !isInForeground else { return }
        if let last = lastFrameProcessed, now.timeIntervalSince(last) > 2 {
            DiagnosticLog.shared.log(.app, String(format: "no frame was processed for %.1f s while in the background (the stream stalled, or iOS suspended the app)", now.timeIntervalSince(last)))
        }
        if now.timeIntervalSince(lastBackgroundLog) > 15 {
            lastBackgroundLog = now
            DiagnosticLog.shared.log(.app, "running in the background: \(BackgroundActivity.remainingDescription)")
        }
    }

    private func appendLiveSample(for value: Telemetry1) {
        let now = Date()
        if let last = liveHistory.last, now.timeIntervalSince(last.date) < Self.liveHistoryInterval { return }
        liveHistory.append(LiveSample(
            date: now,
            speedKmh: value.speedKmh(scaled: telemetry2?.speedScalingFlag ?? false),
            powerWatts: value.power,
            voltage: value.voltage,
            current: value.current,
            batteryPercent: value.batteryPercent,
            controllerTemperature: value.controllerTemperature,
            motorTemperature: value.motorTemperature
        ))
        let cutoff = now.addingTimeInterval(-Self.liveHistoryWindow)
        if let firstKept = liveHistory.firstIndex(where: { $0.date >= cutoff }), firstKept > 0 {
            liveHistory.removeFirst(firstKept)
        }
    }

    private func publish(force: Bool) {
        let elapsed = ContinuousClock.now - lastPublish
        if force || elapsed >= Self.publishInterval {
            publishNow(forceSnapshot: force)
            return
        }
        guard publishTask == nil else { return }
        let wait = Self.publishInterval - elapsed
        publishTask = Task {
            do { try await Task.sleep(for: wait) } catch { return }
            self.publishNow(forceSnapshot: false)
        }
    }

    /// The UI republishes at 10 Hz, but the snapshot consumers (widgets, Live Activity, alerts, rides) need about 1 Hz.
    private func publishNow(forceSnapshot: Bool) {
        publishTask?.cancel()
        publishTask = nil
        lastPublish = ContinuousClock.now
        telemetry1 = latestTelemetry1
        if regenEnergyWh != regenAccumulator { regenEnergyWh = regenAccumulator }
        if let latest = latestTelemetry1 {
            let speed = latest.speedKmh(scaled: telemetry2?.speedScalingFlag ?? false)
            if speed > peakSpeedKmh { peakSpeedKmh = speed }
        }
        if forceSnapshot || ContinuousClock.now - lastSnapshotEmit >= Self.snapshotInterval {
            emitSnapshot()
        }
    }

    private func emitSnapshot() {
        lastSnapshotEmit = ContinuousClock.now
        onSnapshot?(makeSnapshot())
    }

    func makeSnapshot() -> ScooterSnapshot {
        let t1 = latestTelemetry1
        let register = effectiveRegister
        let locked: Bool = register.map { FeatureFlags.lockFlagMeansLocked ? $0.lockFlag : !$0.lockFlag } ?? false
        return ScooterSnapshot(
            updatedAt: Date(),
            isConnected: connection.isConnected,
            batteryPercent: t1?.batteryPercent,
            rangeKm: rangeKm,
            speedKmh: t1.map { $0.speedKmh(scaled: telemetry2?.speedScalingFlag ?? false) } ?? 0,
            gearRaw: register?.gearBits,
            headlightOn: register?.headlight ?? false,
            isLocked: locked,
            tripKm: t1?.tripKm,
            totalKm: t1?.totalKm,
            controllerTemperature: t1?.controllerTemperature,
            motorTemperature: t1?.motorTemperature,
            current: t1?.current,
            lastSeen: lastTelemetryDate,
            lastRide: lastRide,
            usesMiles: UserDefaults.standard.bool(forKey: "useMiles")
        )
    }

    private func record(_ direction: FrameLogEntry.Direction, label: String, bytes: [UInt8]) {
        guard isFrameLoggingEnabled else { return }
        frameLog.append(FrameLogEntry(date: Date(), direction: direction, label: label, bytes: bytes))
        if frameLog.count > Self.logCapacity { frameLog.removeFirst(frameLog.count - Self.logCapacity) }
    }

    private func present(_ message: String) {
        DiagnosticLog.shared.log(.error, "shown to the rider: \(message)")
        addNotice(message, kind: .problem)
        alertTask?.cancel()
        alertMessage = message
        alertSeverity = nil
        alertTask = Task {
            do { try await Task.sleep(for: Self.alertDuration) } catch { return }
            self.alertMessage = nil
        }
    }

    // MARK: Notification center

    /// A rule fired: shows the banner in the severity's colour and keeps the entry in the notification center.
    func presentAlert(_ message: String, severity: AlertSeverity) {
        addNotice(message, kind: .alert)
        alertTask?.cancel()
        alertMessage = message
        alertSeverity = severity
        alertTask = Task {
            do { try await Task.sleep(for: Self.alertDuration * (severity == .critical ? 2 : 1)) } catch { return }
            self.alertMessage = nil
            self.alertSeverity = nil
        }
    }

    /// Adds an entry without showing the banner, for alerts that already reached the person as a system notification.
    func logAlert(_ message: String) {
        addNotice(message, kind: .alert)
    }

    private func addNotice(_ message: String, kind: Notice.Kind) {
        // The same problem repeating every second must not flood the list.
        if let last = notices.last, last.message == message, Date().timeIntervalSince(last.date) < 30 { return }
        notices.append(Notice(date: Date(), message: message, kind: kind))
        if notices.count > Self.noticeCapacity { notices.removeFirst(notices.count - Self.noticeCapacity) }
        unreadNoticeCount += 1
    }

    func markNoticesRead() {
        unreadNoticeCount = 0
    }

    func removeNotice(_ id: Notice.ID) {
        notices.removeAll { $0.id == id }
        unreadNoticeCount = min(unreadNoticeCount, notices.count)
    }

    func clearNotices() {
        notices.removeAll()
        unreadNoticeCount = 0
        dismissAlert()
    }

    // MARK: AT commands and settings

    private func receiveReply(_ bytes: [UInt8]) {
        do {
            atInbox.append(try ATReply.parse(bytes))
        } catch {
            unparsedReplies.append(String(decoding: bytes, as: UTF8.self))
        }
    }

    private func perform(_ command: ATCommand) async throws -> ATReply {
        guard connection.isConnected else { throw LinkFailure.notConnected }
        // Another command may be in flight, for example the settings load after connecting. Wait for it
        // instead of failing, so a tap on Save never loses against a background read.
        var waited = 0
        while isRunningCommand {
            if waited >= 200 { throw LinkFailure.busy }
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        guard connection.isConnected else { throw LinkFailure.notConnected }
        isRunningCommand = true
        defer { isRunningCommand = false }

        let bytes = try command.encoded()
        atInbox.removeAll()
        unparsedReplies.removeAll()
        record(.tx, label: "AT", bytes: command.redactedForLog(bytes))
        try await link.writeCommand(bytes)

        for _ in 0..<40 {
            if let reply = atInbox.first(where: { $0.key == command.expectedReplyKey }) {
                guard reply.isOK else { throw LinkFailure.commandRejected("ERR+\(reply.key)") }
                return reply
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let raw = unparsedReplies.last { throw ProtocolError.unrecognizedATReply(raw) }
        throw LinkFailure.timeout
    }

    func refreshSettings() async {
        guard !isLoadingSettings else { return }
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        // The Pure app never uses the turn-signal sound command and this scooter does not answer it, so it is not asked.
        let queries: [ATCommand] = [.queryPINEnabled, .queryDevice]
        var next = settings
        next.failures = [:]
        for query in queries {
            do {
                let reply = try await performRetryingOnce(query)
                switch reply.key {
                case "TYPE": next.pinEnabled = reply.value == "B"
                case "DEVICE": next.deviceDescription = reply.value
                default: break
                }
            } catch is CancellationError {
                return
            } catch {
                next.failures[query.expectedReplyKey] = error.localizedDescription
            }
            settings = next
        }
        next.saveToCache()
    }

    /// A late answer from the scooter is common, so a read gets a second try.
    private func performRetryingOnce(_ command: ATCommand) async throws -> ATReply {
        do {
            return try await perform(command)
        } catch LinkFailure.timeout {
            try await Task.sleep(for: .milliseconds(300))
            return try await perform(command)
        }
    }

    @discardableResult
    private func run(_ command: ATCommand, onSuccess: (inout ScooterSettings) -> Void = { _ in }) async -> Bool {
        do {
            _ = try await perform(command)
            onSuccess(&settings)
            settings.saveToCache()
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error.localizedDescription)
            return false
        }
    }

    func setPINEnabled(_ enabled: Bool) async {
        await run(.setPINEnabled(enabled)) { $0.pinEnabled = enabled }
    }

    /// Checks the old PIN, writes the new one, then checks the new one before saving it on this phone.
    /// The scooter itself does not need the old PIN, so this guard protects against typos and casual changes.
    func changePIN(from oldPIN: String, to newPIN: String) async -> Bool {
        do {
            let check = try await perform(.verifyPIN(oldPIN))
            guard check.value == "Y" else {
                present("The current PIN is wrong.")
                return false
            }
            _ = try await perform(.changePIN(newPIN))
            let confirm = try await perform(.verifyPIN(newPIN))
            guard confirm.value == "Y" else {
                present("The scooter accepted the new PIN but did not confirm it. Your saved PIN was not changed.")
                return false
            }
            PINVault.pin = newPIN
            return true
        } catch is CancellationError {
            return false
        } catch {
            present(error.localizedDescription)
            return false
        }
    }



    func rename(suffix: String) async -> Bool {
        await run(.rename(suffix: suffix)) { $0.deviceDescription = GATT.namePrefix + suffix }
    }

    // MARK: Controller info

    func readControllerInfo() async {
        guard connection.isConnected else {
            present(LinkFailure.notConnected.localizedDescription)
            return
        }
        guard speedKmh <= ControlFrame.standstillThresholdKmh else {
            present("Stop the scooter before reading controller info. Live data pauses briefly while it is read.")
            return
        }
        guard !isReadingController else { return }
        isReadingController = true
        defer { isReadingController = false }
        do {
            let readout = try await link.readControllerInfo()
            controllerReadout = readout
            let record = FirmwareRecord(readout.info)
            firmwareRecord = record
            record.save()
        } catch is CancellationError {
            return
        } catch {
            present(error.localizedDescription)
        }
    }

    func clearLog() {
        frameLog.removeAll()
    }
}

extension ScooterStore {
    static func preview(
        connection: ConnectionState = .connected,
        register: UInt16 = 0x0c02,
        speedRaw: UInt16 = 18_400
    ) -> ScooterStore {
        let store = ScooterStore(link: MockScooter(behavior: .init(simulatesRide: false)))
        let caps = SpeedCaps(eco: 6, comfort: 12, sport: 22)
        let frame1 = FrameEncoder.telemetry1(
            gear: UInt8(register & 3), batteryPercent: 76, speedRaw: speedRaw, voltageDeci: 398,
            currentRaw: 4 * 64, controllerTemperature: 34, motorTemperature: 41, tripDeci: 52,
            totalDeci: 3_184, register0: register
        )
        let frame2 = FrameEncoder.telemetry2(limitCruise: 3, caps: caps, flags: 0x0100)
        store.connection = connection
        store.latestTelemetry1 = try! Telemetry1(parsing: frame1)
        store.telemetry1 = store.latestTelemetry1
        store.telemetry2 = try! Telemetry2(parsing: frame2)
        store.lastTelemetryDate = Date()
        let now = Date()
        store.liveHistory = (0..<300).map { second in
            let t = Double(second)
            let speed = max(0, 14 + 8 * sin(t / 14))
            return LiveSample(
                date: now.addingTimeInterval(t - 300), speedKmh: speed, powerWatts: speed * 13 + 20 * sin(t / 5),
                voltage: 41.2 - speed * 0.05, current: speed * 0.33,
                batteryPercent: 79 - second / 100, controllerTemperature: 30 + second / 20, motorTemperature: 36 + second / 14
            )
        }
        return store
    }
}


private extension ATCommand {
    /// PINs never go into the frame log.
    func redactedForLog(_ bytes: [UInt8]) -> [UInt8] {
        switch self {
        case .verifyPIN: Array("AT+PWD[******]".utf8)
        case .changePIN: Array("AT+PWDM[******]".utf8)
        default: bytes
        }
    }
}
