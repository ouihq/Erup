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
}

actor ScooterConnection: ScooterLink {
    nonisolated let events: AsyncStream<LinkEvent>

    private static let restoreIdentifier = "me.ouihq.erup.central"
    private static let silenceTimeout: Duration = .seconds(5)
    private static let maximumBackoffSeconds = 30
    private static let bridgeWaitPolls = 20
    private static let bridgeWatchdogTimeout: Duration = .seconds(15)

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
    private var bridgeActive = false
    private var bridgeOwner: UUID?
    private var bridgeWatchdog: Task<Void, Never>?
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
        central = CBCentralManager(
            delegate: delegate,
            queue: DispatchQueue(label: "me.ouihq.erup.central"),
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
        guard !bridgeActive else { throw LinkFailure.busy }
        let owner = UUID()
        bridgeOwner = owner
        bridgeActive = true
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
        guard bridgeActive else { return }
        if let owner, owner != bridgeOwner { return }
        bridgeWatchdog?.cancel()
        bridgeWatchdog = nil
        bridgeOwner = nil
        bridgeActive = false
        bridgeBacklog.removeAll()
        bridgeDecoder.reset()
        decoder.reset()
        if sessionActive {
            sendNow(SessionFrames.leaveBridge)
            // The keep-alive was paused while the bridge was open. Resume it at once so the scooter keeps streaming.
            sendKeepAlive()
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
            restored = peripherals
        case .discovered(let found, let name, let rssi):
            handleDiscovered(found, name: name, rssi: rssi)
        case .connected(let connected):
            guard connected.identifier == peripheral?.identifier else { return }
            setState(.connecting)
            beginDiscovery(on: connected)
        case .failedToConnect(let failed, let error):
            guard failed.identifier == peripheral?.identifier else { return }
            emitter.yield(.failure(.bluetooth(error?.localizedDescription ?? "Could not connect to the scooter.")))
            setState(.searching(Self.hint(for: error)))
            scheduleReconnect()
        case .disconnected(let lost, let error):
            guard lost.identifier == peripheral?.identifier else { return }
            endSession()
            setState(.searching(Self.hint(for: error)))
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
        }
    }

    private func handleManagerState(_ managerState: CBManagerState) {
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
            self.reconnectIfStillNeeded()
        }
    }

    private func reconnectIfStillNeeded() {
        guard let target = peripheral, target.state == .disconnected,
              central?.state == .poweredOn else { return }
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
        receivedTelemetry = false
        telemetryFrameCount = 0
        lastKeepAlive = nil
        decoder.reset()
        writeQueue.enqueue(.init(channel: .data, bytes: SessionFrames.start))
        flushWrites()
        keepAliveTask = Task { await self.runKeepAlive() }
        silenceTask = Task { await self.watchForSilence() }
    }

    private func endSession() {
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
        bridgeOwner = nil
        bridgeActive = false
        bridgeBacklog.removeAll()
        bridgeDecoder.reset()
    }

    private func noteTelemetryFrame() {
        if !receivedTelemetry {
            receivedTelemetry = true
            reconnectAttempt = 0
            silenceTask?.cancel()
            setState(.connected)
        }
        telemetryFrameCount += 1
        if telemetryFrameCount % SessionFrames.telemetryFramesPerKeepAlive == 0 {
            sendKeepAlive()
        }
    }

    private func runKeepAlive() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: SessionFrames.keepAliveInterval) } catch { return }
            let now = ContinuousClock.now
            if let lastKeepAlive, now - lastKeepAlive < SessionFrames.keepAliveInterval { continue }
            sendKeepAlive()
        }
    }

    private func sendKeepAlive() {
        guard sessionActive, !bridgeActive else { return }
        lastKeepAlive = ContinuousClock.now
        writeQueue.enqueue(.init(channel: .data, bytes: SessionFrames.keepAlive, isKeepAlive: true))
        flushWrites()
    }

    private func watchForSilence() async {
        do { try await Task.sleep(for: Self.silenceTimeout) } catch { return }
        if sessionActive, !receivedTelemetry { setState(.searching(.silent)) }
    }

    private func flushWrites() {
        guard let target = peripheral, target.state == .connected else { return }
        while target.canSendWriteWithoutResponse, let item = writeQueue.popFirst() {
            let id = item.channel == .data ? GATT.dataWrite : GATT.commandWrite
            guard let characteristic = characteristics[id] else {
                emitter.yield(.failure(.characteristicMissing(id)))
                continue
            }
            target.writeValue(Data(item.bytes), for: characteristic, type: .withoutResponse)
        }
    }

    private func fail(_ error: Error) {
        emitter.yield(.failure(.bluetooth(error.localizedDescription)))
    }

    private func setState(_ newState: ConnectionState) {
        guard newState != state else { return }
        state = newState
        emitter.yield(.state(newState))
    }
}
