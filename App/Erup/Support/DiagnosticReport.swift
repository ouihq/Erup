import CoreLocation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The diagnostic log plus the facts needed to read it, ready to share as a text file.
struct DiagnosticReport: Transferable {
    let header: [(String, String)]
    let frames: [String]

    var text: String { DiagnosticLog.shared.report(header: header, frames: frames) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { report in
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Erup-diagnostics-\(stamp).txt")
            try report.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }

    /// Facts that explain most background problems: the versions, Low Power Mode and what the link was doing.
    @MainActor
    static func header(for store: ScooterStore) -> [(String, String)] {
        let process = ProcessInfo.processInfo
        var items: [(String, String)] = [
            ("App", AppVersion.display),
            ("iOS", UIDevice.current.systemVersion),
            ("Device", Self.deviceModel),
            ("Low Power Mode", process.isLowPowerModeEnabled ? "ON (iOS limits background activity)" : "off"),
            ("Background App Refresh", Self.refreshStatus),
            ("Thermal state", "\(process.thermalState.rawValue) (0 nominal, 3 critical)"),
            ("Connection", "\(store.connection)"),
            ("Last frame", store.lastTelemetryDate.map { String(format: "%.1f s ago", Date().timeIntervalSince($0)) } ?? "never"),
            ("Bluetooth firmware", store.deviceInfo.firmwareRevision ?? "unknown"),
            ("Frame logging", store.isFrameLoggingEnabled ? "on" : "off"),
            ("Automatic reads", FeatureFlags.pauseAutomaticReads ? "PAUSED (debug test)" : "on"),
            ("When the stream stalls", StallRecovery.current.title),
            ("End a ride after standing still", "\(Int(RideSettings.endAfterStanding / 60)) min"),
            ("Join rides within", RideSettings.joinWithin == 0 ? "off" : "\(Int(RideSettings.joinWithin / 60)) min"),
            ("Joining reaches a standing-still split", RideSettings.joiningReachesStandstillSplits ? "yes" : "no (the window is not longer than the standing time)"),
            ("Write mode", FeatureFlags.forceWriteWithoutResponse ? "forced WITHOUT response (debug)" : "with response when the scooter allows it"),
            ("Stay connected with the screen off", BackgroundKeepAlive.isEnabled ? "ON (location session keeps the app running)" : "off (iOS suspends the app soon after the screen locks)"),
            ("Location permission", Self.locationStatus),
        ]
        items.append(("Privacy", "no PIN, scooter name or Bluetooth identifiers are included"))
        return items
    }

    @MainActor
    private static var locationStatus: String {
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: "not asked yet"
        case .denied: "DENIED"
        case .restricted: "restricted"
        case .authorizedWhenInUse: "while using the app"
        case .authorizedAlways: "always"
        @unknown default: "unknown"
        }
    }

    private static var deviceModel: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    @MainActor
    private static var refreshStatus: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: "on"
        case .denied: "OFF for this app"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
    }
}
