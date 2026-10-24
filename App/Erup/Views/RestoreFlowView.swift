import SwiftData
import SwiftUI

/// Where a backup to restore comes from.
enum RestoreSource: Identifiable {
    /// A file the rider chose, or one opened from Files.
    case file(URL)
    /// The newest backup in the chosen backup folder.
    case folder(URL)

    var id: String {
        switch self {
        case .file(let url): "file:\(url.path)"
        case .folder(let url): "folder:\(url.path)"
        }
    }

    func load() async throws -> Data {
        switch self {
        case .file(let url):
            try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }.value
        case .folder(let url):
            try await Task.detached(priority: .userInitiated) { try BackupFolder.latest(in: url).data }.value
        }
    }
}

/// Reads a backup, shows what is in it, and puts it onto this iPhone once the rider confirms.
struct RestoreFlowView: View {
    let source: RestoreSource
    @Environment(ScooterStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var rides: [Ride]

    private enum Phase {
        case reading
        case ready(BackupArchive, BackupService.Summary)
        case restoring
        case done(BackupService.RestoreResult)
        case failed(String)
    }

    @State private var phase = Phase.reading
    @State private var mode = BackupService.RestoreMode.merge
    @State private var includeSettings = true
    @State private var confirmsReplace = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Restore a backup")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if case .done = phase { EmptyView() } else { Button("Cancel") { dismiss() } }
                    }
                }
        }
        .task { await read() }
        .interactiveDismissDisabled(isBusy)
    }

    private var isBusy: Bool {
        switch phase {
        case .reading, .restoring: true
        default: false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .reading:
            progress("Reading the backup…")
        case .restoring:
            progress("Restoring…")
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't restore", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
            }
        case .done(let result):
            ContentUnavailableView {
                Label("Restored", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } description: {
                Text(resultText(result))
            } actions: {
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        case .ready(let archive, let summary):
            form(archive, summary)
        }
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func form(_ archive: BackupArchive, _ summary: BackupService.Summary) -> some View {
        Form {
            Section("In the backup") {
                LabeledContent("Rides", value: "\(summary.rideCount)")
                if let first = summary.firstRide, let last = summary.lastRide {
                    LabeledContent("Period") {
                        Text("\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                LabeledContent("Distance", value: Measurement(value: summary.totalDistanceKm, unit: UnitLength.kilometers).formatted(.measurement(width: .abbreviated, usage: .road)))
                LabeledContent("Made", value: summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Erup version", value: summary.app)
            }

            Section {
                LabeledContent("Rides", value: "\(rides.count)")
            } header: {
                Text("On this iPhone")
            }

            Section {
                Picker("How", selection: $mode) {
                    Text("Add missing rides").tag(BackupService.RestoreMode.merge)
                    Text("Replace all rides").tag(BackupService.RestoreMode.replace)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if summary.settingCount > 0 {
                    Toggle("Restore settings", isOn: $includeSettings)
                }
            } header: {
                Text("How to restore")
            } footer: {
                Text(mode == .merge
                     ? "Rides already on this iPhone are kept as they are. Only the ones that are missing are added."
                     : "Deletes the \(rides.count) rides on this iPhone and puts the backup's rides in their place.")
            }

            Section {
                Button {
                    if mode == .replace { confirmsReplace = true } else { restore(archive) }
                } label: {
                    Text(mode == .merge ? "Add missing rides" : "Replace rides")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .confirmationDialog("Replace all rides?", isPresented: $confirmsReplace, titleVisibility: .visible) {
            Button("Delete \(rides.count) rides and restore", role: .destructive) { restore(archive) }
        } message: {
            Text("The rides on this iPhone are deleted. Make a backup first if you want to keep them.")
        }
    }

    private func resultText(_ result: BackupService.RestoreResult) -> String {
        var parts = ["\(result.added) \(result.added == 1 ? "ride" : "rides") added"]
        if result.skipped > 0 { parts.append("\(result.skipped) already on this iPhone") }
        if result.removed > 0 { parts.append("\(result.removed) replaced") }
        if result.settings > 0 { parts.append("settings restored") }
        return parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst() + "."
    }

    private func read() async {
        do {
            let data = try await source.load()
            let archive = try await BackupService.decode(data)
            phase = .ready(archive, BackupService.summary(of: archive))
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func restore(_ archive: BackupArchive) {
        phase = .restoring
        Task {
            do {
                let result = try await BackupService.restore(archive, mode: mode, includeSettings: includeSettings, into: context)
                store.invalidateRideContext()
                phase = .done(result)
            } catch {
                phase = .failed("The restore failed: \(error.localizedDescription). Your rides were not changed.")
            }
        }
    }
}
