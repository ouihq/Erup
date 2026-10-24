import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Backing up and restoring: a file to keep anywhere, and a folder in iCloud Drive that Erup keeps filled by itself.
struct BackupSettingsView: View {
    @Environment(ScooterStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(BackupScheduler.self) private var scheduler
    @Query private var rides: [Ride]

    @AppStorage(BackupScheduler.enabledKey) private var automatic = true
    @AppStorage(BackupScheduler.lastDateKey) private var lastStamp = 0.0
    @AppStorage(BackupScheduler.lastBytesKey) private var lastBytes = 0
    @AppStorage(BackupScheduler.lastErrorKey) private var lastError = ""

    @State private var folder: URL? = BackupFolder.resolved()
    @State private var document = BackupDocument()
    @State private var showsSaver = false
    @State private var showsFilePicker = false
    @State private var showsFolderPicker = false
    @State private var isMakingFile = false
    @State private var restoreSource: RestoreSource?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button {
                    makeFile()
                } label: {
                    HStack {
                        Label("Save a backup file…", systemImage: "square.and.arrow.down")
                        if isMakingFile { Spacer(); ProgressView() }
                    }
                }
                .disabled(isMakingFile)
                Button {
                    showsFilePicker = true
                } label: {
                    Label("Restore from a file…", systemImage: "arrow.counterclockwise")
                }
            } header: {
                Text("Backup file")
            } footer: {
                Text("One file with all \(rides.count) rides, their sensor data and routes, and your settings. Save it to iCloud Drive, Files or send it to another device. Tapping a backup file in Files opens it here. The PIN and the paired scooter are never included.")
            }

            folderSection
        }
        .navigationTitle("Backup and restore")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $showsSaver, document: document, contentType: .erupBackup, defaultFilename: BackupService.fileName()) { result in
            if case .failure(let error) = result { message = "The backup could not be saved: \(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.erupBackup, .data]) { result in
            switch result {
            case .success(let url): restoreSource = .file(url)
            case .failure(let error): message = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showsFolderPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): chooseFolder(url)
            case .failure(let error): message = error.localizedDescription
            }
        }
        .sheet(item: $restoreSource) { RestoreFlowView(source: $0) }
        .alert("Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: Folder

    @ViewBuilder
    private var folderSection: some View {
        Section {
            LabeledContent("Folder", value: folder.map(BackupFolder.displayName) ?? "Not chosen")
            Button {
                showsFolderPicker = true
            } label: {
                Label(folder == nil ? "Choose a folder…" : "Choose another folder…", systemImage: "icloud")
            }
            if let folder {
                Toggle("Back up automatically", isOn: $automatic)
                LabeledContent("Last backup") {
                    if lastStamp > 0 {
                        Text("\(Date(timeIntervalSince1970: lastStamp).formatted(date: .abbreviated, time: .shortened)) · \(Int64(lastBytes).formatted(.byteCount(style: .file)))")
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("Never")
                    }
                }
                if !lastError.isEmpty {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    backUpNow()
                } label: {
                    HStack {
                        Label("Back up now", systemImage: "arrow.triangle.2.circlepath.icloud")
                        if scheduler.isRunning { Spacer(); ProgressView() }
                    }
                }
                .disabled(scheduler.isRunning)
                Button {
                    restoreSource = .folder(folder)
                } label: {
                    Label("Restore the latest backup…", systemImage: "icloud.and.arrow.down")
                }
                Button("Stop using this folder", role: .destructive) {
                    BackupFolder.forget()
                    self.folder = nil
                }
            }
        } header: {
            Text("Backup folder")
        } footer: {
            Text("Pick or create a folder in iCloud Drive and Erup keeps a backup there: after a ride, and when you open the app if the last one is a day old. The one before is kept next to it. Erup can't use iCloud directly when it is installed through AltStore, so it uses a folder you choose in Files; iCloud Drive syncs it to your other devices and keeps it when you delete Erup.")
        }
    }

    private func chooseFolder(_ url: URL) {
        do {
            try BackupFolder.remember(url)
            folder = BackupFolder.resolved()
            automatic = true
            backUpNow()
        } catch {
            message = "The folder could not be used: \(error.localizedDescription)"
        }
    }

    private func backUpNow() {
        Task {
            do { try await scheduler.backUpNow() } catch { message = error.localizedDescription }
        }
    }

    private func makeFile() {
        isMakingFile = true
        Task {
            defer { isMakingFile = false }
            do {
                document = BackupDocument(data: try await BackupScheduler.makeData(container: context.container))
                showsSaver = true
            } catch {
                message = "The backup could not be made: \(error.localizedDescription)"
            }
        }
    }
}

#Preview("Backup and restore, dark") {
    NavigationStack { BackupSettingsView() }
        .environment(ScooterStore.preview())
        .environment(BackupScheduler(container: Ride.previewContainer()))
        .modelContainer(Ride.previewContainer())
        .preferredColorScheme(.dark)
}
