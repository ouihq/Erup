import CoreBluetooth
import Foundation
import ScooterProtocol

private enum CBEvent: @unchecked Sendable {
    case stateChanged(CBManagerState)
    case willRestore([CBPeripheral])
    case discovered(CBPeripheral, name: String?, rssi: Int)
    case connected(CBPeripheral)
    case failedToConnect(CBPeripheral, Error?)
    case disconnected(CBPeripheral, Error?)
    case discoveredServices(CBPeripheral, Error?)
    case discoveredCharacteristics(CBPeripheral, CBService, Error?)
    case notificationState(CBPeripheral, characteristic: UInt16?, isNotifying: Bool, Error?)
    case value(CBPeripheral, characteristic: UInt16?, bytes: [UInt8], Error?)
    case readyToWrite(CBPeripheral)
    case wroteValue(CBPeripheral, characteristic: UInt16?, Error?)
}

private extension CBUUID {
    static func short(_ value: UInt16) -> CBUUID {
        CBUUID(string: String(format: "%04X", value))
    }

    var shortValue: UInt16? {
        let bytes = [UInt8](data)
        guard bytes.count == 2 else { return nil }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }
}

private final class CentralDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CBEvent>.Continuation

    init(continuation: AsyncStream<CBEvent>.Continuation) {
        self.continuation = continuation
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        continuation.yield(.stateChanged(central.state))
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        continuation.yield(.willRestore(peripherals))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        continuation.yield(.discovered(peripheral, name: name, rssi: RSSI.intValue))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        continuation.yield(.connected(peripheral))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        continuation.yield(.failedToConnect(peripheral, error))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        continuation.yield(.disconnected(peripheral, error))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        continuation.yield(.discoveredServices(peripheral, error))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        continuation.yield(.discoveredCharacteristics(peripheral, service, error))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        continuation.yield(.notificationState(
            peripheral, characteristic: characteristic.uuid.shortValue, isNotifying: characteristic.isNotifying, error
        ))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        continuation.yield(.value(
            peripheral,
            characteristic: characteristic.uuid.shortValue,
            bytes: characteristic.value.map { [UInt8]($0) } ?? [],
            error
        ))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        continuation.yield(.readyToWrite(peripheral))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        continuation.yield(.wroteValue(peripheral, characteristic: characteristic.uuid.shortValue, error))
    }
}

actor ScooterConnection: ScooterLink {
    nonisolated let events: AsyncStream<LinkEvent>

    private static let restoreIdentifier = "me.ouihq.erup.central"
    private static let silenceTimeout: Duration = .seconds(5)
    private static let maximumBackoffSeconds = 30
    private static let bridgeWaitPolls = 20
    private static let bridgeWatchdogTimeout: Duration = .seconds(15)
    private static let bridgeStaleAfter: Duration = .seconds(10)
    /// When frames arrive but no keep-alive went out for this long, send one now. The count-based rule and the
    /// timer can both be late while iOS has the app suspended; an arriving frame is the one thing that wakes it.
    private static let keepAliveSafetyInterval: Duration = .seconds(1)
    private static let healthLogInterval: Duration = .seconds(15)
    private static let writeAckTimeout: Duration = .seconds(3)
    private static let log = DiagnosticLog.shared

    private let emitter: AsyncStream<LinkEvent>.Continuation
    private let cbStream: AsyncStream<CBEvent>
    private let delegate: CentralDelegate
    private let pairing: PairingStorage

    private var central: CBCentralManager?
    private var eventLoop: Task<Void, Never>?
    private var peripheral: CBPeripheral?
    private var restored: [CBPeripheral] = []
    private var scanned: [UUID: CBPeripheral] = [:]
    private var wantsScan = false

    private var characteristics: [UInt16: CBCharacteristic] = [:]
    private var sessionActive = false
    private var receivedTelemetry = false
    private var state: ConnectionState = .unpaired
    private var deviceInfo = DeviceInfo()

    private var writeQueue = WriteQueue()
    private var decoder = TelemetryDecoder()
    private var bridgeDecoder = BridgeReplyDecoder()
    private var bridgeLease = BridgeLease()
    private var bridgeActive: Bool { bridgeLease.isActive }
    private var bridgeWatchdog: Task<Void, Never>?
    private var bridgeStartedAt: ContinuousClock.Instant?
    private var lastFrameAt: ContinuousClock.Instant?
    private var stallPolicy = StreamStallPolicy()
    private var keepAliveGate = KeepAliveGate()
    private var framesInWindow = 0
    private var keepAlivesInWindow = 0
    private var writesInWindow = 0
    private var blockedInWindow = 0
    private var blockedSinceLastFrame = 0
    /// The last write that was not a keep-alive, so a stall can be tied to what the app sent just before it.
    private var lastOtherWrite: (label: String, at: ContinuousClock.Instant)?
    private var bridgeClosedAt: ContinuousClock.Instant?
    /// Writes with response are acknowledged one at a time, like the official Android app does. The send buffer of
    /// writes without response was full for seconds on a phone during rides, which starved the scooter of keep-alives.
    private var responseWriteInFlight: ContinuousClock.Instant?
    private var responseWritesDisabled = false
    private var missedAcknowledgements = 0
    private var acksInWindow = 0
    private var slowestAckInWindow: Duration = .zero
    private var lastStallStartedLog: ContinuousClock.Instant?
    private var lastHealthLog = ContinuousClock.now
    private var bridgeBacklog: [BridgeEvent] = []
    private var telemetryFrameCount = 0
    private var lastKeepAlive: ContinuousClock.Instant?
    private var keepAliveTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0

    init(pairing: PairingStorage = PairingStorage()) {
        let (eventStream, eventContinuation) = AsyncStream.makeStream(of: LinkEvent.self)
        let (cbStream, cbContinuation) = AsyncStream.makeStream(of: CBEvent.self)
        self.events = eventStream
        self.emitter = eventContinuation
        self.cbStream = cbStream
        self.delegate = CentralDelegate(continuation: cbContinuation)
        self.pairing = pairing
    }

    // MARK: ScooterLink

    func start() {
        guard central == nil else { return }
        Self.log.log(.connection, "Bluetooth started (paired scooter: \(pairing.peripheralID == nil ? "none" : "saved"))")
        central = CBCentralManager(
            delegate: delegate,
            queue: DispatchQueue(label: "me.ouihq.erup.central", qos: .userInitiated),
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
        eventLoop = Task { await self.runEventLoop() }
    }

    func beginPairingScan() {
        wantsScan = true
        startScanIfPossible()
    }

    func endPairingScan() {
        wantsScan = false
        central?.stopScan()
        if state == .scanning { setState(pairing.peripheralID == nil ? .unpaired : .searching(.waiting)) }
    }

    func pair(with id: UUID) {
        guard let candidate = scanned[id], let central else { return }
        wantsScan = false
        central.stopScan()
        pairing.peripheralID = id
        adopt(candidate)
        setState(.searching(.waiting))
        central.connect(candidate, options: nil)
    }

    func forget() {
        reconnectTask?.cancel()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        endSession()
        peripheral = nil
        pairing.peripheralID = nil
        setState(.unpaired)
    }

    func write(_ frame: [UInt8]) throws {
        guard sessionActive else { throw LinkFailure.notConnected }
        guard !bridgeActive else { throw LinkFailure.busy }
        writeQueue.enqueue(.init(channel: .data, bytes: frame))
        flushWrites()
    }

    func writeCommand(_ bytes: [UInt8]) throws {
        guard sessionActive else { throw LinkFailure.notConnected }
        writeQueue.enqueue(.init(channel: .command, bytes: bytes))
        flushWrites()
    }

    func readControllerInfo() async throws -> ControllerReadout {
        let owner = try await beginBridge()
        do {
            try await Task.sleep(for: .milliseconds(200))
            let readout = try await collectReadout()
            leaveBridge(owner: owner)
            return readout
        } catch {
            leaveBridge(owner: owner)
            throw error
        }
    }

    func lockControlWord(setLockBit set: Bool?) async throws -> UInt16 {
        let owner = try await beginBridge()
        do {
            try await Task.sleep(for: .milliseconds(200))
            var word = try await readControlWord()
            let lockBit: UInt16 = 1 << UInt16(ControllerRegister.Bit.lock)
            if let set, (word & lockBit != 0) != set {
                let next = set ? word | lockBit : word & ~lockBit
                bridgeBacklog.removeAll()
                sendNow(BridgeFrames.writeControlWord(next))
                try await Task.sleep(for: .milliseconds(250))
                word = try await readControlWord()
            }
            leaveBridge(owner: owner)
            return word
        } catch {
            leaveBridge(owner: owner)
            throw error
        }
    }

    /// The original app sends the enter-bridge frame again before every read cycle, so a late or dropped answer
    /// is retried the same way instead of failing after one try.
    private func readControlWord() async throws -> UInt16 {
        for attempt in 0..<3 {
            bridgeBacklog.removeAll()
            if attempt > 0 {
                sendNow(SessionFrames.enterBridge)
                try await Task.sleep(for: .milliseconds(200))
            }
            sendNow(BridgeFrames.readControlWordRequest)
            do {
                for _ in 0..<4 {
                    switch try await nextBridgeEvent(polls: 16) {
                    case .data(BridgeFrames.readRegistersFunction, 0, let payload) where payload.count >= 2:
                        return UInt16(payload[0]) << 8 | UInt16(payload[1])
                    case .failure(let error):
                        throw error
                    default:
                        continue
                    }
                }
            } catch LinkFailure.timeout {
                continue
            }
        }
        throw LinkFailure.timeout
    }

    private func collectReadout() async throws -> ControllerReadout {
        var infoBytes: [UInt8] = []
        for request in BridgeFrames.controllerInfoRequests {
            bridgeBacklog.removeAll()
            sendNow(request)
            switch try await nextBridgeEvent() {
            case .data(_, _, let payload): infoBytes += payload
            case .failure(let error): throw error
            case .written: throw LinkFailure.timeout
            }
        }
        let info = try ControllerInfo(bytes: infoBytes)

        bridgeBacklog.removeAll()
        sendNow(BridgeFrames.batteryInfoRequest)
        do {
            switch try await nextBridgeEvent() {
            case .data(_, _, let payload):
                return ControllerReadout(info: info, batteryBytes: payload, batteryNote: nil)
            case .failure(let error):
                return ControllerReadout(info: info, batteryBytes: nil, batteryNote: error.localizedDescription)
            case .written:
                return ControllerReadout(info: info, batteryBytes: nil, batteryNote: LinkFailure.timeout.localizedDescription)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ControllerReadout(info: info, batteryBytes: nil, batteryNote: error.localizedDescription)
        }
    }

    private func nextBridgeEvent(polls: Int = 40) async throws -> BridgeEvent {
        for _ in 0..<polls {
            if !bridgeBacklog.isEmpty { return bridgeBacklog.removeFirst() }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LinkFailure.timeout
    }

    /// Bridge mode swallows telemetry and pauses the keep-alive, so only one exchange may run at a time. A
    /// short wait covers an exchange that is about to finish; a stale one is cleared by its watchdog.
    private func beginBridge() async throws -> UUID {
        guard sessionActive else { throw LinkFailure.notConnected }
        for _ in 0..<Self.bridgeWaitPolls where bridgeActive {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard sessionActive else { throw LinkFailure.notConnected }
        guard let owner = bridgeLease.acquire() else {
            Self.log.log(.bridge, "bridge exchange refused: another one is still open")
            throw LinkFailure.busy
        }
        Self.log.log(.bridge, "bridge exchange opened (telemetry pauses while it is open)")
        bridgeStartedAt = .now
        bridgeDecoder.reset()
        bridgeBacklog.removeAll()
        // iOS can suspend the app in the middle of an exchange. Without this the bridge would stay open after
        // it resumes: telemetry stays swallowed and every later lock or control write fails as busy.
        bridgeWatchdog?.cancel()
        bridgeWatchdog = Task {
            do { try await Task.sleep(for: Self.bridgeWatchdogTimeout) } catch { return }
            self.leaveBridge(owner: owner)
        }
        sendNow(SessionFrames.enterBridge)
        return owner
    }

    /// Only the exchange that opened the bridge (or its watchdog) may close it, so a late finisher cannot
    /// close a newer exchange.
    private func leaveBridge(owner: UUID? = nil) {
        guard bridgeLease.release(owner: owner) else {
            Self.log.log(.bridge, "a late bridge exchange tried to close a newer one, ignored")
            return
        }
        let open = bridgeStartedAt.map { Self.seconds(ContinuousClock.now - $0) } ?? "?"
        Self.log.log(.bridge, "bridge exchange closed after \(open) s")
        bridgeStartedAt = nil
        bridgeClosedAt = .now
        bridgeWatchdog?.cancel()
        bridgeWatchdog = nil
        bridgeBacklog.removeAll()
        bridgeDecoder.reset()
        decoder.reset()
        if sessionActive {
            sendNow(SessionFrames.leaveBridge)
            // Do not send a keep-alive right behind the leave frame: that stops the stream (see KeepAliveGate). The
            // timer and the frame-driven rule resume it once the hold is over.
            keepAliveGate.holdAfterBridge(now: .now)
        }
    }

    private func sendNow(_ bytes: [UInt8]) {
        writeQueue.enqueue(.init(channel: .data, bytes: bytes))
        flushWrites()
    }

    // MARK: Event handling

    private func runEventLoop() async {
        for await event in cbStream {
            handle(event)
        }
    }

    private func handle(_ event: CBEvent) {
        switch event {
        case .stateChanged(let managerState):
            handleManagerState(managerState)
        case .willRestore(let peripherals):
            Self.log.log(.connection, "iOS restored the Bluetooth session (\(peripherals.count) peripheral(s)): the app was relaunched or woken for it")
            restored = peripherals
        case .discovered(let found, let name, let rssi):
            handleDiscovered(found, name: name, rssi: rssi)
        case .connected(let connected):
            guard connected.identifier == peripheral?.identifier else { return }
            Self.log.log(.connection, "link established, discovering services")
            setState(.connecting)
            beginDiscovery(on: connected)
        case .failedToConnect(let failed, let error):
            guard failed.identifier == peripheral?.identifier else { return }
            Self.log.log(.connection, "connection attempt failed: \(Self.describe(error))")
            emitter.yield(.failure(.bluetooth(error?.localizedDescription ?? "Could not connect to the scooter.")))
            setState(.searching(Self.hint(for: error)))
            scheduleReconnect()
        case .disconnected(let lost, let error):
            guard lost.identifier == peripheral?.identifier else { return }
            let quiet = lastFrameAt.map { "\(Self.seconds(ContinuousClock.now - $0)) s since the last frame" } ?? "no frame received"
            Self.log.log(.connection, "link lost: \(Self.describe(error)); \(quiet); bridge \(bridgeActive ? "open" : "closed")")
            endSession()
            setState(.searching(Self.hint(for: error)))
            // Ask for the connection right now. A pending connect never times out and keeps working while the
            // app is suspended; the timer below does not, because a suspended app never gets to run it.
            requestConnectionNow()
            scheduleReconnect()
        case .discoveredServices(let target, let error):
            guard target.identifier == peripheral?.identifier else { return }
            if let error { return fail(error) }
            discoverCharacteristics(on: target)
        case .discoveredCharacteristics(let target, let service, let error):
            guard target.identifier == peripheral?.identifier else { return }
            if let error { return fail(error) }
            register(service.characteristics ?? [], on: target)
        case .notificationState(let target, let characteristic, let isNotifying, let error):
            guard target.identifier == peripheral?.identifier else { return }
            if let error { return fail(error) }
            if characteristic == GATT.dataNotify, isNotifying, !sessionActive { beginSession() }
        case .value(let target, let characteristic, let bytes, let error):
            guard target.identifier == peripheral?.identifier else { return }
            if let error { return fail(error) }
            handleValue(characteristic, bytes)
        case .readyToWrite(let target):
            guard target.identifier == peripheral?.identifier else { return }
            flushWrites()
        case .wroteValue(let target, _, let error):
            guard target.identifier == peripheral?.identifier else { return }
            handleWriteAcknowledgement(error: error)
        }
    }

    private func handleManagerState(_ managerState: CBManagerState) {
        Self.log.log(.connection, "bluetooth manager state: \(Self.name(of: managerState))")
        switch managerState {
        case .poweredOn:
            if wantsScan { startScanIfPossible() }
            connectToPairedScooter()
        case .poweredOff:
            endSession()
            setState(.bluetoothOff)
        case .unauthorized:
            setState(.unauthorized)
        case .unsupported:
            setState(.unsupported)
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handleDiscovered(_ found: CBPeripheral, name: String?, rssi: Int) {
        guard let name, name.hasPrefix(GATT.namePrefix) else { return }
        scanned[found.identifier] = found
        emitter.yield(.discovered(DiscoveredScooter(id: found.identifier, name: name, rssi: rssi)))
    }

    private func handleValue(_ characteristic: UInt16?, _ bytes: [UInt8]) {
        switch characteristic {
        case GATT.dataNotify where bridgeActive:
            bridgeBacklog.append(contentsOf: bridgeDecoder.feed(bytes))
        case GATT.dataNotify:
            for event in decoder.feed(bytes) {
                lastFrameAt = .now
                emitter.yield(.telemetry(event))
                if case .telemetry1 = event { noteTelemetryFrame() }
            }
        case GATT.commandNotify:
            emitter.yield(.commandReply(bytes))
        case GATT.firmwareRevision:
            deviceInfo.firmwareRevision = String(decoding: bytes, as: UTF8.self)
            emitter.yield(.deviceInfo(deviceInfo))
        case GATT.systemID:
            deviceInfo.systemID = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            emitter.yield(.deviceInfo(deviceInfo))
        default:
            break
        }
    }

    // MARK: Connecting

    private func startScanIfPossible() {
        guard let central, central.state == .poweredOn else { return }
        scanned.removeAll()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        setState(.scanning)
    }

    private func connectToPairedScooter() {
        guard let central else { return }
        guard let id = pairing.peripheralID else {
            if !wantsScan { setState(.unpaired) }
            return
        }
        let candidate = restored.first { $0.identifier == id }
            ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let candidate else {
            emitter.yield(.failure(.peripheralUnknown))
            pairing.peripheralID = nil
            setState(.unpaired)
            return
        }
        adopt(candidate)
        switch candidate.state {
        case .connected:
            setState(.connecting)
            beginDiscovery(on: candidate)
        case .connecting:
            setState(.searching(.waiting))
        case .disconnected, .disconnecting:
            setState(.searching(.waiting))
            central.connect(candidate, options: nil)
        @unknown default:
            setState(.searching(.waiting))
            central.connect(candidate, options: nil)
        }
    }

    private func adopt(_ candidate: CBPeripheral) {
        peripheral = candidate
        candidate.delegate = delegate
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = reconnectAttempt == 0 ? 0.5 : Double(min(Self.maximumBackoffSeconds, 1 << min(reconnectAttempt - 1, 5)))
        reconnectAttempt += 1
        reconnectTask = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self.requestConnectionNow()
        }
    }

    private func requestConnectionNow() {
        guard let target = peripheral, target.state == .disconnected,
              central?.state == .poweredOn else { return }
        Self.log.log(.connection, "requesting connection (stays pending until the scooter is reachable)")
        central?.connect(target, options: nil)
    }

    private static func hint(for error: Error?) -> ConnectionState.SearchHint {
        guard let code = (error as? CBError)?.code else { return .waiting }
        switch code {
        case .connectionTimeout: return .outOfRange
        case .peripheralDisconnected: return .scooterOff
        default: return .waiting
        }
    }

    // MARK: Discovery

    private func beginDiscovery(on target: CBPeripheral) {
        endSession()
        target.discoverServices([
            .short(GATT.dataService), .short(GATT.commandService), .short(GATT.deviceInformationService),
        ])
    }

    private func discoverCharacteristics(on target: CBPeripheral) {
        for service in target.services ?? [] {
            switch service.uuid.shortValue {
            case GATT.dataService:
                target.discoverCharacteristics([.short(GATT.dataWrite), .short(GATT.dataNotify)], for: service)
            case GATT.commandService:
                target.discoverCharacteristics([.short(GATT.commandWrite), .short(GATT.commandNotify)], for: service)
            case GATT.deviceInformationService:
                target.discoverCharacteristics([.short(GATT.firmwareRevision), .short(GATT.systemID)], for: service)
            default:
                break
            }
        }
    }

    private func register(_ found: [CBCharacteristic], on target: CBPeripheral) {
        for characteristic in found {
            guard let id = characteristic.uuid.shortValue else { continue }
            characteristics[id] = characteristic
            switch id {
            case GATT.dataNotify, GATT.commandNotify:
                target.setNotifyValue(true, for: characteristic)
            case GATT.firmwareRevision, GATT.systemID:
                target.readValue(for: characteristic)
            default:
                break
            }
        }
    }

    // MARK: Session

    private func beginSession() {
        guard let write = characteristics[GATT.dataWrite] else {
            emitter.yield(.failure(.characteristicMissing(GATT.dataWrite)))
            return
        }
        guard write.properties.contains(.writeWithoutResponse) else {
            emitter.yield(.failure(.writeWithoutResponseUnsupported))
            return
        }
        sessionActive = true
        responseWriteInFlight = nil
        Self.log.log(.stream, "session started: notifications on, start frame sent; writes go out \(usesResponse(write) ? "WITH response (acknowledged, like the official app)" : "without response")")
        receivedTelemetry = false
        telemetryFrameCount = 0
        lastKeepAlive = nil
        lastFrameAt = nil
        stallPolicy.reset()
        decoder.reset()
        writeQueue.enqueue(.init(channel: .data, bytes: SessionFrames.start))
        flushWrites()
        keepAliveTask = Task { await self.runKeepAlive() }
        silenceTask = Task { await self.watchForSilence() }
    }

    private func endSession() {
        if sessionActive { Self.log.log(.stream, "session ended (\(telemetryFrameCount) frames this session)") }
        keepAliveTask?.cancel()
        silenceTask?.cancel()
        keepAliveTask = nil
        silenceTask = nil
        writeQueue.removeAll()
        characteristics.removeAll()
        decoder.reset()
        sessionActive = false
        receivedTelemetry = false
        bridgeWatchdog?.cancel()
        bridgeWatchdog = nil
        bridgeLease.release()
        bridgeStartedAt = nil
        bridgeClosedAt = nil
        keepAliveGate.reset()
        responseWriteInFlight = nil
        lastFrameAt = nil
        stallPolicy.reset()
        bridgeBacklog.removeAll()
        bridgeDecoder.reset()
    }

    private func noteTelemetryFrame() {
        if stallPolicy.isRecovering, let last = lastStallStartedLog {
            Self.log.log(.stream, "frames are back after the keep-alive burst, no reconnect needed (\(Self.seconds(ContinuousClock.now - last)) s)")
        }
        stallPolicy.reset()
        lastStallStartedLog = nil
        blockedSinceLastFrame = 0
        if !receivedTelemetry {
            receivedTelemetry = true
            reconnectAttempt = 0
            silenceTask?.cancel()
            setState(.connected)
        } else if state != .connected {
            // The stream came back after a stall that had been shown as a lost connection.
            setState(.connected)
        }
        telemetryFrameCount += 1
        framesInWindow += 1
        if telemetryFrameCount % SessionFrames.telemetryFramesPerKeepAlive == 0 {
            sendKeepAlive()
        } else if let last = lastKeepAlive, ContinuousClock.now - last >= Self.keepAliveSafetyInterval {
            Self.log.log(.stream, "keep-alive was \(Self.seconds(ContinuousClock.now - last)) s late, sent on frame arrival")
            sendKeepAlive()
        }
        logHealthIfDue()
    }

    private func runKeepAlive() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: SessionFrames.keepAliveInterval) } catch { return }
            let now = ContinuousClock.now
            checkForStall()
            if let lastKeepAlive, now - lastKeepAlive < SessionFrames.keepAliveInterval { continue }
            sendKeepAlive()
        }
    }

    /// The scooter ends its stream when keep-alives stop, for example while iOS had the app suspended, and it
    /// does not disconnect. Notice the silence, restart the stream, and fall back to a full reconnect.
    private func checkForStall() {
        guard sessionActive, receivedTelemetry, let lastFrameAt else { return }
        let now = ContinuousClock.now
        if bridgeActive {
            // An exchange the app was suspended in the middle of would otherwise swallow telemetry for good.
            if let started = bridgeStartedAt, now - started > Self.bridgeStaleAfter { leaveBridge() }
            return
        }
        let silentFor = now - lastFrameAt
        // Frames that arrived after the exchange closed prove the stream came back.
        let afterBridge = bridgeClosedAt.map { $0 > lastFrameAt } ?? false
        if stallPolicy.showsAsSilent(silentFor: silentFor, afterBridge: afterBridge), state == .connected {
            Self.log.log(.stream, "no frames for \(Self.seconds(silentFor)) s, showing the link as lost")
            setState(.searching(.silent))
        }
        switch stallPolicy.evaluate(silentFor: silentFor, afterBridge: afterBridge, recovery: StallRecovery.current) {
        case .none:
            return
        case .sendKeepAlives:
            Self.log.log(.stream, "stream stalled: \(stallContext(silentFor: silentFor, lastFrameAt: lastFrameAt)). Trying a keep-alive burst first, which needs no reconnect")
            lastStallStartedLog = .now
            Task { await self.sendKeepAliveBurst() }
        case .reconnect:
            Self.log.log(.stream, "the keep-alive burst did not help after \(Self.seconds(silentFor)) s. Dropping the link to reconnect (the scooter beeps when it reconnects)")
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        }
    }

    /// Three keep-alives, spaced out because the write queue keeps only one waiting at a time. On a real scooter this
    /// revived a stalled stream within half a second.
    private func sendKeepAliveBurst() async {
        for index in 0..<3 {
            lastKeepAlive = nil
            sendKeepAlive()
            if index < 2 { try? await Task.sleep(for: .milliseconds(100)) }
        }
    }

    /// What the app was doing around the last frame, to find what triggers a stall.
    private func stallContext(silentFor: Duration, lastFrameAt: ContinuousClock.Instant) -> String {
        var parts = ["no frame for \(Self.seconds(silentFor)) s"]
        if let other = lastOtherWrite {
            let before = lastFrameAt - other.at
            let when = before >= .zero ? "\(Self.seconds(before)) s before the last frame" : "\(Self.seconds(.zero - before)) s after the last frame"
            parts.append("last non-keep-alive write: \(other.label), \(when)")
        } else {
            parts.append("no non-keep-alive write this session")
        }
        parts.append("\(writeQueue.count) write(s) waiting, radio buffer full \(blockedSinceLastFrame)x since the last frame")
        if let sent = responseWriteInFlight {
            parts.append("a write has waited \(Self.seconds(ContinuousClock.now - sent)) s for its acknowledgement")
        }
        parts.append("bridge \(bridgeActive ? "open" : "closed")")
        return parts.joined(separator: "; ")
    }

    /// Called when the app returns to the foreground: clear an exchange that was left open and check the stream now.
    func resumeAfterBackground() {
        guard sessionActive else { return }
        if bridgeActive, let started = bridgeStartedAt, ContinuousClock.now - started > .seconds(3) { leaveBridge() }
        checkForStall()
    }

    private func logHealthIfDue() {
        let now = ContinuousClock.now
        guard now - lastHealthLog >= Self.healthLogInterval else { return }
        Self.log.log(.stream, "stream ok: \(framesInWindow) frames in \(Self.seconds(now - lastHealthLog)) s; keep-alives queued \(keepAlivesInWindow), writes sent \(writesInWindow), acknowledged \(acksInWindow) (slowest \(Int(Double(slowestAckInWindow.components.attoseconds) / 1e15 + Double(slowestAckInWindow.components.seconds) * 1000)) ms), radio buffer full \(blockedInWindow)x")
        lastHealthLog = now
        framesInWindow = 0
        keepAlivesInWindow = 0
        writesInWindow = 0
        blockedInWindow = 0
        acksInWindow = 0
        slowestAckInWindow = .zero
    }

    private func sendKeepAlive() {
        guard sessionActive, !bridgeActive, keepAliveGate.allows(at: .now) else { return }
        lastKeepAlive = ContinuousClock.now
        if writeQueue.enqueue(.init(channel: .data, bytes: SessionFrames.keepAlive, isKeepAlive: true)) {
            keepAlivesInWindow += 1
        }
        flushWrites()
    }

    private func watchForSilence() async {
        do { try await Task.sleep(for: Self.silenceTimeout) } catch { return }
        if sessionActive, !receivedTelemetry { setState(.searching(.silent)) }
    }

    private func usesResponse(_ characteristic: CBCharacteristic) -> Bool {
        !responseWritesDisabled && !FeatureFlags.forceWriteWithoutResponse && characteristic.properties.contains(.write)
    }

    private func flushWrites() {
        guard let target = peripheral, target.state == .connected else { return }
        var blocked = false
        while let item = writeQueue.first {
            let id = item.channel == .data ? GATT.dataWrite : GATT.commandWrite
            guard let characteristic = characteristics[id] else {
                _ = writeQueue.popFirst()
                emitter.yield(.failure(.characteristicMissing(id)))
                continue
            }
            if usesResponse(characteristic) {
                if let sent = responseWriteInFlight {
                    // One acknowledged write at a time; the next goes out when the answer arrives.
                    guard ContinuousClock.now - sent > Self.writeAckTimeout else { blocked = true; break }
                    noteMissingAcknowledgement()
                    continue
                }
                _ = writeQueue.popFirst()
                responseWriteInFlight = .now
                target.writeValue(Data(item.bytes), for: characteristic, type: .withResponse)
            } else {
                guard target.canSendWriteWithoutResponse else { blocked = true; break }
                _ = writeQueue.popFirst()
                target.writeValue(Data(item.bytes), for: characteristic, type: .withoutResponse)
            }
            writesInWindow += 1
            if !item.isKeepAlive {
                let label = Self.label(for: item)
                lastOtherWrite = (label, .now)
                Self.log.log(.stream, "wrote \(label)")
            }
        }
        if blocked {
            blockedInWindow += 1
            blockedSinceLastFrame += 1
        }
    }

    private func handleWriteAcknowledgement(error: Error?) {
        if let sent = responseWriteInFlight {
            let latency = ContinuousClock.now - sent
            acksInWindow += 1
            if latency > slowestAckInWindow { slowestAckInWindow = latency }
        }
        responseWriteInFlight = nil
        if let error {
            // The characteristic does not take writes with response after all: go back to the old way for good.
            Self.log.log(.error, "a write with response failed (\(Self.describe(error))). Falling back to writes without response")
            responseWritesDisabled = true
        } else {
            missedAcknowledgements = 0
        }
        flushWrites()
    }

    private func noteMissingAcknowledgement() {
        responseWriteInFlight = nil
        missedAcknowledgements += 1
        Self.log.log(.stream, "no acknowledgement for a write within \(Self.seconds(Self.writeAckTimeout)) s (\(missedAcknowledgements) in a row)")
        if missedAcknowledgements >= 2 {
            Self.log.log(.error, "writes with response are not acknowledged on this link. Falling back to writes without response")
            responseWritesDisabled = true
        }
    }

    private static func label(for item: WriteQueue.Item) -> String {
        if item.channel == .command { return "AT command (\(item.bytes.count) bytes)" }
        switch item.bytes {
        case SessionFrames.start: return "start / leave-bridge frame"
        case SessionFrames.enterBridge: return "enter-bridge frame"
        default: return "\(item.bytes.count)-byte data frame (control or bridge request)"
        }
    }

    private func fail(_ error: Error) {
        emitter.yield(.failure(.bluetooth(error.localizedDescription)))
    }

    private func setState(_ newState: ConnectionState) {
        guard newState != state else { return }
        Self.log.log(.connection, "state \(state) -> \(newState)")
        state = newState
        emitter.yield(.state(newState))
    }

    // MARK: Log text

    private static func seconds(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.1f", Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    private static func name(of state: CBManagerState) -> String {
        switch state {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .poweredOff: "powered off"
        case .poweredOn: "powered on"
        @unknown default: "other"
        }
    }

    /// Core Bluetooth says why a link ended. Timeout (6) means the radio link was lost, for example out of range or
    /// iOS not answering in time; peripheral disconnected (7) means the scooter ended the link itself.
    private static func describe(_ error: Error?) -> String {
        guard let error else { return "no error (clean disconnect)" }
        let ns = error as NSError
        var name = ""
        if ns.domain == CBErrorDomain, let code = CBError.Code(rawValue: ns.code) {
            switch code {
            case .connectionTimeout: name = " (connection timeout: radio link lost)"
            case .peripheralDisconnected: name = " (the scooter ended the link)"
            case .connectionFailed: name = " (connection failed)"
            case .peerRemovedPairingInformation: name = " (scooter removed pairing info)"
            case .encryptionTimedOut: name = " (encryption timed out)"
            case .operationCancelled: name = " (cancelled by the app)"
            default: break
            }
        }
        return "\(ns.domain) code \(ns.code)\(name): \(ns.localizedDescription)"
    }
}
