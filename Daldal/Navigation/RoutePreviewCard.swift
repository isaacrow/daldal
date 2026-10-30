@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI
import SwiftUI

/// Route options to a destination, with one big Start button.
struct RoutePreviewCard: View {
    let onStart: () -> Void
    let onRetry: () -> Void

    @Environment(NavigationModel.self) private var nav

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack(spacing: Theme.Spacing.m) {
                CategoryBadge(icon: .route, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Directions to")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(nav.destination?.name ?? "")
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if nav.routedOnDevice, nav.phase == .preview, !nav.routes.isEmpty {
                    Label { Text("Offline") } icon: { Icon(.download, size: 12) }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Route calculated on your phone, without internet")
                }
            }

            switch nav.phase {
            case .planning:
                HStack(spacing: Theme.Spacing.m) {
                    ProgressView()
                    Text("Finding the best route…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 88)
            default:
                if let message = nav.errorMessage {
                    VStack(spacing: Theme.Spacing.m) {
                        Text(message)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Try again", action: onRetry)
                            .buttonStyle(.glass)
                    }
                    .frame(maxWidth: .infinity, minHeight: 88)
                } else {
                    routeOptions
                    Button(action: onStart) {
                        Label { Text("Start") } icon: { Icon(.navigate, size: 18) }
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(nav.selectedRoute == nil)
                }
            }
        }
        .padding(Theme.Spacing.l)
        .animation(.smooth, value: nav.phase)
    }

    private var routeOptions: some View {
        VStack(spacing: Theme.Spacing.s) {
            ForEach(Array(nav.routes.enumerated()), id: \.offset) { index, route in
                Button { nav.selectedRouteIndex = index } label: {
                    RouteOptionRow(route: route, duration: nav.liveDuration(of: index), trafficDelay: nav.liveDelays[index] ?? 0,
                                   isFastest: index == fastestIndex, isSelected: index == nav.selectedRouteIndex)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var fastestIndex: Int? {
        nav.routes.indices.min { nav.liveDuration(of: $0) < nav.liveDuration(of: $1) }
    }
}

private struct RouteOptionRow: View {
    let route: Route
    /// Including live traffic.
    let duration: TimeInterval
    let trafficDelay: TimeInterval
    let isFastest: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Duration.seconds(duration), format: .units(allowed: [.hours, .minutes], width: .abbreviated))
                    .font(.title3.weight(.bold).monospacedDigit())
                HStack(spacing: Theme.Spacing.s) {
                    Text(Measurement(value: route.distance, unit: UnitLength.meters),
                         format: .measurement(width: .abbreviated, usage: .road))
                        .foregroundStyle(.secondary)
                    if trafficDelay >= 60 {
                        Text("+\(Duration.seconds(trafficDelay), format: .units(allowed: [.hours, .minutes], width: .abbreviated)) traffic")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.subheadline.monospacedDigit())
            }
            Spacer(minLength: 0)
            if isFastest {
                Text("Fastest")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(Theme.accent.opacity(0.15), in: .capsule)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(Theme.Spacing.m)
        .background(isSelected ? Theme.accent.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(isSelected ? Theme.accent : Color.secondary.opacity(0.25),
                                                                 lineWidth: isSelected ? 2 : 1))
        .contentShape(.rect(cornerRadius: 16))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
