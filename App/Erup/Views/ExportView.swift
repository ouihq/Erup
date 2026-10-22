import SwiftData
import SwiftUI

/// Chooses the period and the contents of a data export, then builds the zip and hands it to the share sheet.
struct ExportView: View {
    @Environment(ScooterStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useMiles") private var useMiles = false
    @Query(sort: \Ride.startedAt) private var rides: [Ride]

    private enum Span: String, CaseIterable, Identifiable {
        case all = "All time"
        case week = "Last 7 days"
        case month = "Last 30 days"
        case quarter = "Last 90 days"
        case year = "Last year"
        case custom = "Custom range"

        var id: String { rawValue }

        var days: Int? {
            switch self {
            case .week: 7
            case .month: 30
            case .quarter: 90
            case .year: 365
            default: nil
            }
        }
    }

    @State private var span: Span = .all
    @State private var customFrom = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    @State private var customTo = Date.now
    @State private var rideList = true
    @State private var sensorData = true
    @State private var routes = true
    @State private var detailedFiles = false
    @State private var isExporting = false
    @State private var exportedFile: ExportedFile?

    private var options: DataExporter.Options {
        let calendar = Calendar.current
        var options = DataExporter.Options(rideList: rideList, sensorData: sensorData, routes: routes, detailedFiles: detailedFiles)
        if let days = span.days {
            options.from = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: .now))
        } else if span == .custom {
            options.from = calendar.startOfDay(for: min(customFrom, customTo))
            options.to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(customFrom, customTo)))
        }
        return options
    }

    private var rideCount: Int {
        let options = options
        return rides.reduce(0) { $0 + (options.includes($1.startedAt) ? 1 : 0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Period", selection: $span) {
                        ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if span == .custom {
                        DatePicker("From", selection: $customFrom, in: ...Date.now, displayedComponents: .date)
                        DatePicker("To", selection: $customTo, in: ...Date.now, displayedComponents: .date)
                    }
                } header: {
                    Text("Time span")
                } footer: {
                    Text(rideCount == 1 ? "1 ride in this period." : "\(rideCount) rides in this period.")
                }

                Section {
                    option("Ride list", "One row per ride: distance, speeds, energy, battery, temperatures.", $rideList)
                    option("Sensor data", "Speed, power, battery and voltage over time. The largest part of an export.", $sensorData)
                    option("Routes", "The GPS route of each ride as a GPX file.", $routes)
                    option("One file per ride", "Everything about a ride in a single JSON file.", $detailedFiles)
                } header: {
                    Text("Include")
                } footer: {
                    Text("Totals and the chosen period are always saved in summary.json. The scooter PIN is never exported.")
                }

                Section {
                    Button {
                        export()
                    } label: {
                        HStack {
                            Spacer()
                            if isExporting {
                                ProgressView()
                            } else {
                                Text("Create export").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isExporting || rideCount == 0 || options.isEmpty)
                }
            }
            .navigationTitle("Export data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(item: $exportedFile) { file in ShareSheet(url: file.url).ignoresSafeArea() }
        }
    }

    private func option(_ title: String, _ detail: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func export() {
        isExporting = true
        let options = options
        Task {
            defer { isExporting = false }
            do {
                let chosen = rides.filter { options.includes($0.startedAt) }
                let records = chosen.map(DataExporter.Record.init)
                let info = DataExporter.Info(appVersion: AppVersion.display, useMiles: useMiles, zydCode: store.settings.deviceDescription, firmware: store.firmwareRecord)
                // Decoding and writing every sample is slow for a long history, so it must not block the screen.
                let archive = try await Task.detached(priority: .userInitiated) {
                    try DataExporter.makeArchive(records: records, info: info, options: options)
                }.value
                exportedFile = ExportedFile(url: archive)
            } catch {
                store.report("The export failed: \(error.localizedDescription)")
            }
        }
    }
}
