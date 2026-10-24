import SwiftUI
import UniformTypeIdentifiers

/// A backup handed to the file saver, so the rider can put it in iCloud Drive, Files or anywhere else.
struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.erupBackup]
    var data: Data

    init(data: Data = Data()) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
