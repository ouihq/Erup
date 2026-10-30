import Foundation

/// A folder the rider picked in the Files app, usually in iCloud Drive, that Erup writes its backups into.
///
/// iCloud itself (CloudKit, or an app's own iCloud container) needs a capability that an app installed through
/// AltStore cannot have. A folder chosen in Files needs none, and iCloud Drive keeps it in sync all the same.
enum BackupFolder {
    static let bookmarkKey = "backup.folderBookmark"
    static let latestName = "Erup-backup.erupbackup"
    static let previousName = "Erup-backup-previous.erupbackup"
    static let fileExtension = "erupbackup"

    // MARK: Remembering the folder

    static func remember(_ url: URL, defaults: UserDefaults = .standard) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        defaults.set(try url.bookmarkData(), forKey: bookmarkKey)
    }

    static func forget(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: bookmarkKey)
    }

    /// The folder, or nil when none was chosen or it can no longer be found.
    static func resolved(defaults: UserDefaults = .standard) -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale { try? remember(url, defaults: defaults) }
        return url
    }

    /// "Erup" for a plain folder, "Erup · iCloud Drive" for one iCloud keeps in sync.
    static func displayName(for url: URL) -> String {
        let isCloud = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
        return isCloud ? "\(url.lastPathComponent) · iCloud Drive" : url.lastPathComponent
    }

    // MARK: Writing and reading

    /// Writes the backup as the latest one and keeps the one before it next to it, so a bad write never costs the last good copy.
    static func write(_ data: Data, to folder: URL) throws {
        try withAccess(to: folder) {
            let latest = folder.appendingPathComponent(latestName)
            let previous = folder.appendingPathComponent(previousName)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: latest.path) {
                try coordinatedWrite(at: previous) { url in
                    try? fileManager.removeItem(at: url)
                    try fileManager.copyItem(at: latest, to: url)
                }
            }
            try coordinatedWrite(at: latest) { url in try data.write(to: url, options: .atomic) }
        }
    }

    /// The newest backup in the folder: Erup's own latest file, or else the most recently changed `.erupbackup`.
    static func latest(in folder: URL) throws -> (data: Data, date: Date) {
        try withAccess(to: folder) {
            let fileManager = FileManager.default
            let backups = backupFiles(in: folder)
            let newest = backups.max { modified($0) < modified($1) }
            let preferred = backups.first { $0.lastPathComponent == latestName }
            guard let file = preferred ?? newest else { throw BackupError.nothingInFolder }
            if let status = try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus,
               status != .current {
                try? fileManager.startDownloadingUbiquitousItem(at: file)
                throw BackupError.notDownloaded
            }
            return (try coordinatedRead(at: file), modified(file))
        }
    }

    /// Whether the folder already holds a backup, downloaded or not.
    static func containsBackup(in folder: URL) -> Bool {
        (try? withAccess(to: folder) { !backupFiles(in: folder).isEmpty }) ?? false
    }

    private static func backupFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == fileExtension || $0.lastPathComponent.hasSuffix(".\(fileExtension).icloud") }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func withAccess<T>(to folder: URL, _ body: () throws -> T) throws -> T {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: folder.path) else { throw BackupError.folderUnavailable }
        return try body()
    }

    private static func coordinatedWrite(at url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try body(target) } catch { thrown = error }
        }
        if let error = thrown ?? coordinationError { throw error }
    }

    private static func coordinatedRead(at url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let coordinationError { throw coordinationError }
        return try result?.get() ?? Data()
    }
}
