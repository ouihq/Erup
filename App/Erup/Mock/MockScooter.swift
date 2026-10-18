import Foundation
import ScooterProtocol

actor MockScooter: ScooterLink {
    struct Behavior: Sendable {
        var confirmsWrites = true
        var simulatesRide = true
        /// When false the mock behaves like an unpaired scooter until `pair(with:)` is called.
        var startsPaired = true
    }

    nonisolated let events: AsyncStream<LinkEvent>

    private static let tickInterval: Duration = .milliseconds(100)
    private static let confirmationDelay: Duration = .milliseconds(150)
    private static let caps = SpeedCaps(eco: 6, comfort: 12, sport: 22)

    private let emitter: AsyncStream<LinkEvent>.Continuation
    private let behavior: Behavior
    private let pairedID = UUID(uuidString: "00000000-0000-4000-8000-00000000C0DE")!

    private var decoder = TelemetryDecoder()
    private var loop: Task<Void, Never>?
    private var tick = 0
    private var register: UInt16 = 0x0c02
    private var battery = 98.0
    private var baseTotalDeci: UInt32 = 24
    private var tripDeci = 0.0
    private var announcedConnected = false
    private var queuedControls: [UInt8] = []
    private var isApplyingControls = false
    private var isPaired: Bool
    private var lastSpeedKmh = 0.0
    private var regenAmps = 0.0
    private var atState = ATState()

    private struct ATState {
        var pinEnabled = false
        var pin = "888888"
        var pinVerified = false
        var name = "ZYD_Demo"
    }

    init(behavior: Behavior = Behavior()) {
        let (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
        self.events = stream
        self.emitter = continuation
        self.behavior = behavior
        self.isPaired = behavior.startsPaired
    }

    func start() {
        guard isPaired, loop == nil else { return }
        emitter.yield(.state(.connecting))
        emitter.yield(.deviceInfo(DeviceInfo(firmwareRevision: "MOCK-1.0", systemID: "00:00:DE:MO")))
        loop = Task { await self.run() }
    }

    func beginPairingScan() {
        emitter.yield(.state(.scanning))
        emitter.yield(.discovered(DiscoveredScooter(id: pairedID, name: "ZYD_Demo", rssi: -48)))
    }

    func endPairingScan() {}

    func pair(with id: UUID) {
        isPaired = true
        start()
    }

    func forget() {
        loop?.cancel()
        loop = nil
        announcedConnected = false
        isPaired = false
        emitter.yield(.state(.unpaired))
    }

    func write(_ frame: [UInt8]) throws {
        guard loop != nil else { throw LinkFailure.notConnected }
        guard frame.count == ControlFrame.length, CRC16.isValid(frame) else {
            throw LinkFailure.bluetooth("Mock scooter rejected a malformed control frame.")
        }
        guard behavior.confirmsWrites else { return }
        queuedControls.append(frame[3])
        guard !isApplyingControls else { return }
        isApplyingControls = true
        // One worker applies writes in the order they arrived, like the real link does.
        Task { await self.drainControls() }
    }

    private func drainControls() async {
        while !queuedControls.isEmpty {
            do { try await Task.sleep(for: Self.confirmationDelay) } catch { break }
            apply(control: queuedControls.removeFirst())
        }
        queuedControls.removeAll()
        isApplyingControls = false
    }

    func lockControlWord(setLockBit set: Bool?) async throws -> UInt16 {
        guard loop != nil else { throw LinkFailure.notConnected }
        try await Task.sleep(for: .milliseconds(300))
        let lockBit: UInt16 = 1 << UInt16(ControllerRegister.Bit.lock)
        // Like the real scooter, a write is ignored until the PIN was verified (when one is required).
        if let set, behavior.confirmsWrites, atState.pinVerified || !atState.pinEnabled {
            register = set ? register | lockBit : register & ~lockBit
        }
        return register
    }

    func writeCommand(_ bytes: [UInt8]) throws {
        guard loop != nil else { throw LinkFailure.notConnected }
        let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        let reply = respond(to: text)
        Task {
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            self.emitReply(reply)
        }
    }

    func readControllerInfo() async throws -> ControllerReadout {
        func field(_ text: String) -> [UInt8] {
            let bytes = Array(text.utf8)
            return bytes + [UInt8](repeating: 0, count: 16 - bytes.count)
        }
        try await Task.sleep(for: .milliseconds(700))
        let info = try ControllerInfo(bytes: field("MOCK-CTRL") + field("HW 2.1") + field("BL 1.0.3") + field("FW 4.2.7") + field("MOCK0123456789AB"))
        return ControllerReadout(info: info, batteryBytes: Array(0x10..<0x20), batteryNote: nil)
    }

    private func emitReply(_ reply: String) {
        emitter.yield(.commandReply(Array(reply.utf8)))
    }

    private func respond(to rawCommand: String) -> String {
        let command = rawCommand.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        if command.hasPrefix("AT+PWDM") {
            atState.pin = String(command.dropFirst(7))
            return "OK+PWDM"
        } else if command.hasPrefix("AT+PWD") {
            let accepted = command.dropFirst(6) == atState.pin
            atState.pinVerified = accepted
            return "OK+PWD:" + (accepted ? "Y" : "N")
        } else if command.hasPrefix("AT+NAME") {
            atState.name = String(command.dropFirst(7))
            return "OK+NAME:"
        } else if command.hasPrefix("AT+TYPE") {
            let argument = command.dropFirst(7)
            if argument != "?" { atState.pinEnabled = argument == "B" }
            return "OK+TYPE:" + (atState.pinEnabled ? "B" : "A")
        } else if command.hasPrefix("AT+DEVICE") {
            return "OK+DEVICE[\(atState.name)]"
        }
        return "ERR+UNKNOWN"
    }

    private func apply(control ctrl: UInt8) {
        var next = register & ~ControllerRegister.knownMask
        next |= UInt16(ctrl & 0x3)
        let mapping: [(ctrlBit: UInt8, registerBit: Int)] = [
            (2, ControllerRegister.Bit.headlight),
            (3, ControllerRegister.Bit.ambientLight),
            (4, ControllerRegister.Bit.cruiseControl),
            (5, ControllerRegister.Bit.bootMode),
            (6, ControllerRegister.Bit.imperialUnits),
            (7, ControllerRegister.Bit.lock),
        ]
        for entry in mapping where ctrl & (1 << entry.ctrlBit) != 0 {
            next |= 1 << UInt16(entry.registerBit)
        }
        register = next
    }

    private func run() async {
        while !Task.isCancelled {
            advance()
            deliver(telemetry1Bytes())
            if tick % 10 == 0 { deliver(telemetry2Bytes()) }
            do { try await Task.sleep(for: Self.tickInterval) } catch { break }
        }
    }

    private func advance() {
        tick += 1
        let seconds = Double(tick) / 10
        let riding = behavior.simulatesRide && seconds.truncatingRemainder(dividingBy: 60) > 5
        let target = riding ? max(0, 14 + 9 * sin(seconds * 0.15)) : 0
        let before = lastSpeedKmh
        lastSpeedKmh += (target - lastSpeedKmh) * 0.15
        if lastSpeedKmh < 0.05 { lastSpeedKmh = 0 }
        let slowdown = before - lastSpeedKmh
        regenAmps = slowdown > 0.02 ? -min(7, slowdown * 14) : 0
        battery = max(0, battery - 0.0004 * (1 + lastSpeedKmh / 10))
        tripDeci += lastSpeedKmh / 3600 * 0.1 * 10
    }

    private func telemetry1Bytes() -> [UInt8] {
        let current = regenAmps < 0 ? regenAmps : lastSpeedKmh * 0.35
        let voltage = 41.2 - 0.04 * current - (98 - battery) * 0.05
        return FrameEncoder.telemetry1(
            gear: UInt8(register & 0x3),
            batteryPercent: UInt8(battery.rounded()),
            speedRaw: UInt16(lastSpeedKmh * 1000),
            voltageDeci: UInt16(voltage * 10),
            currentRaw: Int16(current * 64),
            controllerTemperature: Int8(22 + lastSpeedKmh / 2),
            motorTemperature: Int8(22 + lastSpeedKmh / 3),
            tripDeci: UInt16(min(Double(UInt16.max), tripDeci)),
            totalDeci: baseTotalDeci + UInt32(tripDeci),
            register0: register
        )
    }

    private func telemetry2Bytes() -> [UInt8] {
        FrameEncoder.telemetry2(limitCruise: 3, caps: Self.caps, flags: 0x0100)
    }

    private func deliver(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 20, bytes.count)
            for event in decoder.feed(Array(bytes[offset..<end])) {
                emitter.yield(.telemetry(event))
                if case .telemetry1 = event, !announcedConnected {
                    announcedConnected = true
                    emitter.yield(.state(.connected))
                }
            }
            offset = end
        }
    }
}
