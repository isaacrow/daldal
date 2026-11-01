@preconcurrency import FerrostarCoreFFI
import MapLibre
import SwiftUI

/// Keeps live traffic and reports drawn on the Drive Mode map, whose style Ferrostar's map view owns.
@MainActor
final class DriveMapOverlay {
    weak var style: MLNStyle?
    /// The route being driven, coloured by live traffic.
    var route: [CLLocationCoordinate2D] = []

    private var carLayer: ModelLayer?

    /// Our car on the map: a smooth Tesla-style model drawn with Metal, turned with the direction of travel and
    /// kept readable at driving zoom.
    func showCar(_ location: UserLocation?) {
        guard let style, let location else { return }
        if carLayer == nil || style.layer(withIdentifier: "car-3d") == nil {
            let layer = ModelLayer(identifier: "car-3d")
            style.addLayer(layer) // On top: never lose your own car behind a building.
            layer.add("car") { device in CarMesh.meshes(device: device) }
            carLayer = layer
        }
        let heading = location.courseOverGround.map { Double($0.degrees) } ?? 0
        carLayer?.set("car", placement: ModelLayer.Placement(coordinate: location.coordinates.coordinate2D, heading: heading,
                                                            height: 1.45, minimumPoints: 26))
    }

    func showRoughSpots(_ spots: [RoughSpot]) {
        guard let style else { return }
        RoughRoadStore.draw(spots, in: style)
    }

    func showRoadFeatures(_ features: [RoadFeature]) {
        guard let style else { return }
        RoadFeatureStore.draw(features, in: style)
    }

    func apply(_ live: LiveStore) {
        guard let style else { return }
        LiveLayers.updateTraffic(live.traffic, in: style)
        LiveLayers.updateReports(live.reports, in: style)
        // Ferrostar draws its route on top of the style, so the colours go on top too (under the car).
        RouteTraffic.draw(RouteTraffic.stretches(along: route, traffic: live.traffic), in: style, above: nil)
    }
}

/// Six big targets, one tap each: reporting has to be quick and glanceable.
struct ReportSheet: View {
    let onReport: (ReportType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Report")
                .font(.title2.weight(.bold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.m), count: 3),
                      spacing: Theme.Spacing.m) {
                ForEach(ReportType.allCases) { type in
                    Button {
                        onReport(type)
                        dismiss()
                    } label: {
                        VStack(spacing: Theme.Spacing.s) {
                            Icon(type.icon, size: 30)
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(Color(red: type.color.red, green: type.color.green, blue: type.color.blue), in: .circle)
                            Text(type.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
    }
}

struct StillThereCard: View {
    let report: LiveReport
    let onAnswer: (Bool) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Icon(report.type.icon, size: 22)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color(red: report.type.color.red, green: report.type.color.green, blue: report.type.color.blue), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.type.title).font(.headline)
                Text("Still there?").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Gone") { onAnswer(false) }
                .buttonStyle(.glass)
            Button("Yes") { onAnswer(true) }
                .buttonStyle(.glassProminent)
        }
        .font(.headline)
        .padding(Theme.Spacing.l)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

struct FasterRouteBanner: View {
    let savings: TimeInterval
    let onSwitch: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Icon(.route, size: 22)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Faster route").font(.headline)
                Text("Saves \(Duration.seconds(savings), format: .units(allowed: [.hours, .minutes], width: .abbreviated))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("No") { onDismiss() }
                .buttonStyle(.glass)
            Button("Switch") { onSwitch() }
                .buttonStyle(.glassProminent)
        }
        .font(.headline)
        .padding(Theme.Spacing.l)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

/// Shown once, on the first drive with live traffic available: say plainly what's shared, offer an off switch.
struct TrafficSharingNotice: View {
    let onTurnOff: () -> Void
    let onOK: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.m) {
                Icon(.traffic, size: 22).foregroundStyle(Theme.accent)
                Text("Live traffic").font(.headline)
            }
            Text("While you drive, Daldal anonymously shares your speed so everyone sees live traffic. The start and end of every trip are never sent.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Turn off", action: onTurnOff).buttonStyle(.glass)
                Spacer()
                Button("OK", action: onOK).buttonStyle(.glassProminent)
            }
        }
        .padding(Theme.Spacing.l)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}
