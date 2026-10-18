import Foundation
import ScooterAnalytics
import SwiftData

/// Keeps the ride history small on the phone.
enum StorageMaintenance {
    private static let packedKey = "storage.compressedV2"

    /// Rewrites rides stored as plain JSON into the compressed form, once, in the background and in small
    /// batches so the app stays responsive. Safe to interrupt: an unfinished run simply continues next launch.
    static func packOldRides(container: ModelContainer) {
        guard !UserDefaults.standard.bool(forKey: packedKey) else { return }
        Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            do {
                _ = try pack(in: context)
                UserDefaults.standard.set(true, forKey: packedKey)
            } catch {
                // Try again at the next launch.
            }
        }
    }

    /// Compresses every ride still stored as plain JSON and returns how many were rewritten.
    @discardableResult
    static func pack(in context: ModelContext) throws -> Int {
        var changed = 0
        for ride in try context.fetch(FetchDescriptor<Ride>()) {
            var dirty = false
            if !PackedData.isPacked(ride.samplesData),
               let samples = try? PackedData.decode([RideSample].self, from: ride.samplesData),
               let packed = try? PackedData.pack(samples) {
                ride.samplesData = packed
                dirty = true
            }
            if let track = ride.trackData, !PackedData.isPacked(track),
               let points = try? PackedData.decode([TrackPoint].self, from: track),
               let packed = try? PackedData.pack(points) {
                ride.trackData = packed
                dirty = true
            }
            if dirty {
                changed += 1
                if changed.isMultiple(of: 10) { try context.save() }
            }
        }
        try context.save()
        return changed
    }

    /// Bytes the ride history takes on disk: the database and the files it keeps next to it.
    static func rideDataBytes() async -> Int64 {
        await Task.detached(priority: .utility) { directoryBytes() }.value
    }

    private nonisolated static func directoryBytes() -> Int64 {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
              let files = FileManager.default.enumerator(at: support, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
