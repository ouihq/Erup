import MapKit
import SwiftUI

/// Slow is a calm violet, fast a bright yellow, so a route reads at a glance: where the rider cruised, and where
/// they opened up. The ramp rises in brightness, so it stays legible on dark maps and satellite imagery alike.
enum RouteSpeedColor {
    private static let stops: [(red: Double, green: Double, blue: Double)] = [
        (0.45, 0.25, 0.95), (0.85, 0.25, 0.70), (1.0, 0.45, 0.30), (1.0, 0.72, 0.15), (1.0, 0.95, 0.35)
    ]

    static func color(_ fraction: Double) -> Color {
        let position = min(max(fraction, 0), 1) * Double(stops.count - 1)
        let lower = min(Int(position), stops.count - 2)
        let t = position - Double(lower)
        let a = stops[lower], b = stops[lower + 1]
        return Color(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t, blue: a.blue + (b.blue - a.blue) * t)
    }

    static var gradient: LinearGradient {
        LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.25).map(color), startPoint: .leading, endPoint: .trailing)
    }
}

/// The route of a ride on a map, colored by speed. Tap the route to look at that moment in the charts; the blue dot
/// shows where the line on a chart is. A menu switches between the map and satellite, a button fits the route again,
/// and another opens it full screen.
///
/// It compares by what it draws (the prepared route, the two markers, the units), so it is not rebuilt while a finger
/// moves on a chart between two points that map to the same spot.
struct RideMapView: View, Equatable {
    let route: RouteGeometry
    var markerIndex: Int?
    var topSpeedIndex: Int?
    let units: Units
    let onSelect: (Int) -> Void
    var isExpanded = false
    var onClose: () -> Void = {}

    @AppStorage("rides.satelliteMap") private var satellite = false
    @State private var position: MapCameraPosition
    @State private var showsFullScreen = false

    init(route: RouteGeometry, markerIndex: Int? = nil, topSpeedIndex: Int? = nil, units: Units,
         onSelect: @escaping (Int) -> Void, isExpanded: Bool = false, onClose: @escaping () -> Void = {}) {
        self.route = route
        self.markerIndex = markerIndex
        self.topSpeedIndex = topSpeedIndex
        self.units = units
        self.onSelect = onSelect
        self.isExpanded = isExpanded
        self.onClose = onClose
        _position = State(initialValue: .rect(route.fittedRect))
    }

    nonisolated static func == (lhs: RideMapView, rhs: RideMapView) -> Bool {
        lhs.route === rhs.route && lhs.markerIndex == rhs.markerIndex && lhs.topSpeedIndex == rhs.topSpeedIndex
            && lhs.units == rhs.units && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: [.zoom, .pan, .rotate]) {
                routeContent
                markers
            }
            .mapStyle(satellite ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic))
            .mapControls {
                MapScaleView()
                MapCompass()
            }
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local), let index = route.nearestIndex(to: coordinate) else { return }
                onSelect(index)
            }
        }
        .overlay(alignment: .topTrailing) { controls }
        .overlay(alignment: .bottomLeading) { legend }
        .fullScreenCover(isPresented: $showsFullScreen) {
            RideMapView(route: route, markerIndex: markerIndex, topSpeedIndex: topSpeedIndex, units: units, onSelect: onSelect,
                        isExpanded: true, onClose: { showsFullScreen = false })
                .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Route map, colored by speed")
    }

    // MARK: Map content

    @MapContentBuilder
    private var routeContent: some MapContent {
        // A thin dark casing under the colors keeps the route readable on satellite imagery and light maps alike.
        // Satellite imagery is busy and shows the zoom more, so the line is slimmer there.
        let core: CGFloat = satellite ? 3 : 4.5
        MapPolyline(coordinates: route.coordinates)
            .stroke(.black.opacity(0.4), style: StrokeStyle(lineWidth: core + 2, lineCap: .round, lineJoin: .round))
        ForEach(route.segments, id: \.first) { segment in
            MapPolyline(coordinates: Array(route.coordinates[segment.first...segment.last]))
                .stroke(RouteSpeedColor.color(segment.speedKmh / route.maximumSpeedKmh), style: StrokeStyle(lineWidth: core, lineCap: .round, lineJoin: .round))
        }
    }

    @MapContentBuilder
    private var markers: some MapContent {
        if let first = route.coordinates.first {
            Annotation("Start", coordinate: first) { pin(.green) }
        }
        if let last = route.coordinates.last {
            Annotation("End", coordinate: last) { pin(.red) }
        }
        if let topSpeedIndex, route.coordinates.indices.contains(topSpeedIndex) {
            Annotation("Top speed", coordinate: route.coordinates[topSpeedIndex]) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.orange))
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
        if let markerIndex, route.coordinates.indices.contains(markerIndex) {
            Annotation("Selected moment", coordinate: route.coordinates[markerIndex]) {
                Circle().fill(.blue).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .shadow(radius: 3)
            }
        }
    }

    private func pin(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 11, height: 11).overlay(Circle().stroke(.white, lineWidth: 2.5))
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            if isExpanded {
                control("xmark", label: "Close the map") { onClose() }
            } else {
                control("arrow.up.left.and.arrow.down.right", label: "Open the map full screen") { showsFullScreen = true }
            }
            Menu {
                Picker("Map style", selection: $satellite) {
                    Label("Map", systemImage: "map").tag(false)
                    Label("Satellite", systemImage: "globe.europe.africa").tag(true)
                }
            } label: {
                controlLabel("square.2.layers.3d")
            }
            .accessibilityLabel("Map style")
            control("scope", label: "Show the whole route") {
                withAnimation(.smooth) { position = .rect(route.fittedRect) }
            }
        }
        .padding(10)
        .padding(.top, isExpanded ? 44 : 0)
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { controlLabel(symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func controlLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 36, height: 36)
            .background(.regularMaterial, in: Circle())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }

    /// What the colors mean: from standing still to the top speed of this ride.
    private var legend: some View {
        HStack(spacing: 6) {
            Text("0").font(.caption2.weight(.semibold))
            RouteSpeedColor.gradient.frame(width: 56, height: 6).clipShape(Capsule())
            Text("\(units.speed(fromKmh: route.maximumSpeedKmh).formatted(.number.precision(.fractionLength(0)))) \(units.speedLabel)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
        .padding(.bottom, isExpanded ? 24 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Color scale from 0 to \(units.speed(fromKmh: route.maximumSpeedKmh).formatted(.number.precision(.fractionLength(0)))) \(units.speedLabel)")
    }
}
