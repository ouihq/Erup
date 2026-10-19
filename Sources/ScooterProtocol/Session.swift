public enum GATT {
    public static let namePrefix = "ZYD_"

    public static let dataService: UInt16 = 0xF1F0
    public static let dataWrite: UInt16 = 0xF1F1
    public static let dataNotify: UInt16 = 0xF1F2

    public static let commandService: UInt16 = 0xF2F0
    public static let commandWrite: UInt16 = 0xF2F1
    public static let commandNotify: UInt16 = 0xF2F2

    public static let deviceInformationService: UInt16 = 0x180A
    public static let firmwareRevision: UInt16 = 0x2A26
    public static let systemID: UInt16 = 0x2A23
}

public enum SessionFrames {
    public static let start: [UInt8] = [0xA5, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5A]
    public static let keepAlive: [UInt8] = [0xA5, 0x02, 0xFD, 0x5A]
    public static let enterBridge: [UInt8] = [0xA5, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x5A]
    public static let leaveBridge: [UInt8] = start

    /// The scooter keeps streaming for about 2.7 to 3.4 s without a keep-alive. A phone log from rides showed the
    /// write buffer full most of the time at 3 keep-alives per second, so the timer sends one per second. The frame
    /// driven rule (every 5th frame) still sends them sooner while frames flow.
    public static let keepAliveInterval: Duration = .seconds(1)
    public static let telemetryFramesPerKeepAlive = 5
}
