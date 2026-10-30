import Foundation
import Observation
import SwiftData

/// Backs up to the chosen folder by itself: a little after a ride has been saved, and when the app is opened and the last
/// backup is a day old.
@MainActor
@Observable
final class BackupScheduler {
    static let enabledKey = "backup.automatic"
    static let lastDateKey = "backup.lastDate"
    static let lastBytesKey = "backup.lastBytes"
    static let lastErrorKey = "backup.lastError"
    /// A backup is due when the last one is older than this. A little under a day, so opening the app at the same hour works.
    nonisolated static let interval: TimeInterval = 20 * 3600
    /// After a ride is saved the backup waits, in case the next ride joins it.
    static let settleDelay: Duration = .seconds(90)

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// The in-memory store the app falls back to when the database can't be opened. It must never replace a real backup.
    @ObservationIgnored private let isTemporaryStore: Bool
    private(set) var isRunning = false
    @ObservationIgnored var onError: ((String) -> Void)?

    init(container: ModelContainer, defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
        isTemporaryStore = container.configurations.contains (where: \.isStoredInMemoryOnly)
    }

    nonisolated static func isDue(last: Date?, now: Date, interval: TimeInterval = BackupScheduler.interval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    var isEnabled: Bool {
        BackupFolder.resolved(defaults: defaults) != nil && (defaults.object(forKey: Self.enabledKey) as? Bool ?? true)
    }

    var lastBackup: Date? {
        let stamp = defaults.double(forKey: Self.lastDateKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    func rideStored() {
        guard isEnabled else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: Self.settleDelay) } catch { return }
            await self?.runQuietly()
        }
    }

    func appBecameActive() {
        guard isEnabled, Self.isDue(last: lastBackup, now: .now) else { return }
        Task { await runQuietly() }
    }

    private func runQuietly() async {
        do {
            try await backUpNow()
        } catch BackupError.keptExisting {
            // Settings shows why; repeating it on every launch until the first ride would only be noise.
        } catch {
            onError?("The automatic backup failed: \(error.localizedDescription)") }
    }

    /// Writes a backup into the chosen folder. Throws when no folder is chosen or it can't be written.
    func backUpNow() async throws {
        guard !isRunning else { return }
        guard let folder = BackupFolder.resolved(defaults: defaults) else { throw BackupError.noFolder }
        isRunning = true
        defer { isRunning = false }
        do {
            // An empty or temporary ride store would push the real backup out of the folder, for example right after
            // a reinstall, when the rider picks the old folder to restore from.
            if try isTemporaryStore || container.mainContext.fetchCount(FetchDescriptor<Ride>()) == 0,
               BackupFolder.containsBackup(in: folder) {
                throw BackupError.keptExisting
            }
            let data = try await Self.makeData(container: container, defaults: defaults)
            try await Task.detached(priority: .utility) { try BackupFolder.write(data, to: folder) }.value
            defaults.set(Date.now.timeIntervalSince1970, forKey: Self.lastDateKey)
            defaults.set(data.count, forKey: Self.lastBytesKey)
            defaults.removeObject(forKey: Self.lastErrorKey)
        } catch {
            defaults.set(error.localizedDescription, forKey: Self.lastErrorKey)
            throw error
        }
    }

    /// The whole backup as one compressed file, from the rides stored now.
    static func makeData(container: ModelContainer, defaults: UserDefaults = .standard) async throws -> Data {
        let rides = try container.mainContext.fetch(FetchDescriptor<Ride>())
        return try await BackupService.makeData(
            snapshots: BackupService.snapshots(of: rides), settings: BackupSettings.snapshot(of: defaults), appVersion: AppVersion.display
        )
    }
}
