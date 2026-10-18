import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: ScooterSnapshot
}

struct SnapshotProvider: TimelineProvider {
    private static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (SnapshotEntry) -> Void) {
        let snapshot = context.isPreview ? .preview : SnapshotStore.load() ?? .empty
        completion(SnapshotEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: .now, snapshot: SnapshotStore.load() ?? .empty)
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(Self.refreshInterval))))
    }
}

struct ScooterStatusWidget: Widget {
    let kind = "ScooterStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            ScooterStatusView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Scooter")
        .description("Battery, range and when your scooter was last seen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct ScooterStatusView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: ScooterSnapshot

    private var percent: Int? { snapshot.batteryPercent }
    private var fraction: Double { Double(percent ?? 0) / 100 }
    private var rangeText: String { WidgetFormat.distance(snapshot.rangeKm, usesMiles: snapshot.usesMiles) }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: fraction) {
                Image(systemName: "scooter")
            } currentValueLabel: {
                Text(percent.map(String.init) ?? "–")
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Scooter \(percent.map { "\($0)%" } ?? "–")", systemImage: "scooter")
                    .font(.headline)
                Gauge(value: fraction) { EmptyView() }.gaugeStyle(.accessoryLinear)
                lastSeenText.font(.caption2)
            }
        case .accessoryInline:
            Text("\(Image(systemName: "scooter")) \(percent.map { "\($0)%" } ?? "–") · \(rangeText)")
        case .systemMedium:
            HStack(spacing: 16) {
                ring.frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    labeled("Range", rangeText)
                    labeled("Last ride", lastRideText)
                    lastSeenText.font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        default:
            VStack(spacing: 6) {
                ring.frame(width: 84, height: 84)
                Text(rangeText).font(.subheadline.weight(.medium))
                lastSeenText.font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.25), lineWidth: 9)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(percent.map { "\($0)%" } ?? "–")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
    }

    private var tint: Color {
        guard let percent else { return .gray }
        return percent <= 15 ? .red : percent <= 30 ? .orange : .green
    }

    private var lastSeenText: Text {
        if let seen = snapshot.lastSeen {
            Text("Seen \(seen, style: .relative) ago")
        } else {
            Text("Not seen yet")
        }
    }

    private var lastRideText: String {
        guard let ride = snapshot.lastRide else { return "None yet" }
        return WidgetFormat.distance(ride.distanceKm, usesMiles: snapshot.usesMiles)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.headline, design: .rounded)).monospacedDigit()
        }
    }
}

#Preview("Small", as: .systemSmall) {
    ScooterStatusWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
}

#Preview("Medium", as: .systemMedium) {
    ScooterStatusWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
}

#Preview("Lock screen", as: .accessoryRectangular) {
    ScooterStatusWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
}
