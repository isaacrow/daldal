@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI
import FerrostarMapLibreUI
import MapLibreSwiftUI
import SwiftUI

/// Drive Mode: the whole screen is about the next maneuver. Everything else is hidden.
struct DriveModeView: View {
    @Environment(NavigationModel.self) private var nav
    @Environment(OfflinePackManager.self) private var packs
    @Environment(LiveStore.self) private var live
    @Environment(\.colorScheme) private var colorScheme
    @State private var camera: MapViewCamera = .automotiveNavigation(zoom: 17, pitch: 55)
    @State private var confirmingEnd = false
    @State private var reporting = false
    @State private var overlay = DriveMapOverlay()
    @State private var reportSent = false
    @AppStorage("traffic.share") private var shareTraffic = true
    @AppStorage("traffic.noticeShown") private var trafficNoticeShown = false
    @Namespace private var glass

    private var languageCode: String { AppLanguage.code }
    private var phraser: ManeuverPhraser { ManeuverPhraser(languageCode: languageCode) }

    private var styleURL: URL? {
        try? MapStyleBuilder.styleURL(
            isDark: colorScheme == .dark,
            languageCode: languageCode,
            tiles: packs.installed.map(MapTileSource.offline) ?? .online
        )
    }

    var body: some View {
        ZStack {
            if let styleURL {
                NavigationMapView(styleURL: styleURL, camera: $camera, navigationState: nav.state, onStyleLoaded: { style in
                    overlay.style = style
                    overlay.apply(live)
                })
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: Theme.Spacing.s) {
                if nav.phase == .arrived {
                    ArrivalCard(title: phraser.arrived(at: nav.destination?.name)) { nav.stop() }
                } else if let upcoming {
                    ManeuverBanner(maneuver: upcoming.maneuver, distance: upcoming.distance,
                                   lanes: upcoming.lanes, phraser: phraser)
                }
                if let report = nav.stillThere {
                    StillThereCard(report: report) { nav.answerStillThere($0) }
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if let faster = nav.fasterRoute {
                    FasterRouteBanner(savings: faster.savings, onSwitch: nav.acceptFasterRoute, onDismiss: nav.dismissFasterRoute)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if live.isAvailable, !trafficNoticeShown, nav.phase == .navigating {
                    TrafficSharingNotice(
                        onTurnOff: { shareTraffic = false; trafficNoticeShown = true },
                        onOK: { trafficNoticeShown = true }
                    )
                }
                if reportSent {
                    Text("Thanks. Other drivers will see it.")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.vertical, Theme.Spacing.s)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity)
                }
                if nav.state?.isCalculatingNewRoute == true {
                    Text("Finding a better route…")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.vertical, Theme.Spacing.s)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
            .frame(maxWidth: 560)
        }
        .overlay(alignment: .bottom) {
            if nav.phase == .navigating {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    HStack(alignment: .bottom) {
                        SpeedPanel(speed: currentSpeed, limit: nav.speedLimit)
                        Spacer()
                        controls
                    }
                    TripBar(progress: nav.state?.currentProgress) { confirmingEnd = true }
                }
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.bottom, Theme.Spacing.s)
                .frame(maxWidth: 560)
            }
        }
        .animation(.smooth, value: nav.state?.isCalculatingNewRoute)
        .animation(.smooth, value: nav.phase)
        .animation(.smooth, value: nav.stillThere?.id)
        .animation(.smooth, value: nav.fasterRoute?.savings)
        .animation(.smooth, value: reportSent)
        .sheet(isPresented: $reporting) {
            ReportSheet { type in send(type) }
        }
        .onChange(of: live.reports) { overlay.apply(live) }
        .onChange(of: live.traffic) { overlay.apply(live) }
        .sensoryFeedback(.success, trigger: reportSent) { _, sent in sent }
        .confirmationDialog("End this trip?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End trip", role: .destructive) { nav.stop() }
        }
        .persistentSystemOverlays(.hidden)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: Theme.Spacing.s) {
            VStack(spacing: Theme.Spacing.s) {
                if !camera.isTrackingUserLocationWithCourse {
                    GlassIconButton(icon: .navigate, label: "Recenter") {
                        camera = .automotiveNavigation(zoom: 17, pitch: 55)
                    }
                    .glassEffectID("recenter", in: glass)
                    .glassEffectTransition(.matchedGeometry)
                }
                if live.isAvailable {
                    GlassIconButton(icon: .report, label: "Report") { reporting = true }
                        .glassEffectID("report", in: glass)
                }
                GlassIconButton(icon: nav.voice.isMuted ? .volumeOff : .volume,
                                label: nav.voice.isMuted ? "Unmute voice" : "Mute voice") {
                    nav.voice.isMuted.toggle()
                }
                .glassEffectID("mute", in: glass)
            }
        }
        .animation(.smooth, value: camera.isTrackingUserLocationWithCourse)
    }

    private func send(_ type: ReportType) {
        guard let location = nav.state?.preferredUserLocation?.clLocation else { return }
        Task {
            if await live.send(type, at: location) {
                reportSent = true
                try? await Task.sleep(for: .seconds(2.5))
                reportSent = false
            }
        }
    }

    private var currentSpeed: Double? {
        nav.state?.preferredUserLocation?.speed?.value
    }

    private var upcoming: (maneuver: Maneuver, distance: Double, lanes: [LaneInfo])? {
        guard let steps = nav.state?.remainingSteps, let step = steps.first,
              let maneuver = Maneuver(step: step, next: steps.dropFirst().first),
              let distance = nav.state?.currentProgress?.distanceToNextManeuver else { return nil }
        let lanes = nav.state?.currentVisualInstruction?.subContent?.laneInfo
            ?? nav.state?.currentVisualInstruction?.primaryContent.laneInfo ?? []
        return (maneuver, distance, lanes)
    }
}

// MARK: Components

private struct ManeuverBanner: View {
    let maneuver: Maneuver
    let distance: Double
    let lanes: [LaneInfo]
    let phraser: ManeuverPhraser

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.l) {
                ManeuverIcon(maneuver: maneuver, size: 52)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Measurement(value: distance, unit: UnitLength.meters),
                         format: .measurement(width: .abbreviated, usage: .road))
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(phraser.action(maneuver))
                        .font(.headline)
                    if let road = maneuver.roadName {
                        Text(road)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
            }
            if lanes.count > 1 {
                HStack(spacing: 2) {
                    // Lanes are listed left to right on the road, whatever the reading direction.
                    ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                        LaneArrow(directions: lane.directions, activeDirection: lane.activeDirection, isActive: lane.active)
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            }
        }
        .padding(Theme.Spacing.l)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .combine)
        .animation(.smooth, value: Int(distance / 10))
    }
}

private struct SpeedPanel: View {
    let speed: Double? // m/s
    let limit: Measurement<UnitSpeed>?

    private var kmh: Int? { speed.map { Int(($0 * 3.6).rounded()) } }
    private var limitKmh: Int? { limit.map { Int($0.converted(to: .kilometersPerHour).value.rounded()) } }
    private var isSpeeding: Bool {
        guard let kmh, let limitKmh else { return false }
        return kmh > limitKmh + 3 // A little tolerance, like a speedometer's error.
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            VStack(spacing: 0) {
                Text(kmh.map(String.init) ?? "–")
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isSpeeding ? Color.red : .primary)
                    .contentTransition(.numericText())
                Text("km/h")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 64, height: 64)
            .glassEffect(isSpeeding ? .regular.tint(.red.opacity(0.35)) : .regular, in: .circle)

            if let limitKmh {
                // Drawn like a real speed-limit sign: white disc, red ring.
                Text("\(limitKmh)")
                    .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(.white, in: .circle)
                    .overlay(Circle().strokeBorder(.red, lineWidth: 5))
                    .accessibilityLabel(Text("Speed limit \(limitKmh)"))
            }
        }
        .animation(.smooth, value: isSpeeding)
        .accessibilityElement(children: .combine)
    }
}

private struct TripBar: View {
    let progress: TripProgress?
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.l) {
            if let progress {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Date.now.addingTimeInterval(progress.durationRemaining), format: .dateTime.hour().minute())
                        .font(.title2.weight(.bold).monospacedDigit())
                    Text("Arrival")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Duration.seconds(progress.durationRemaining),
                         format: .units(allowed: [.hours, .minutes], width: .abbreviated))
                        .font(.headline.monospacedDigit())
                    Text(Measurement(value: progress.distanceRemaining, unit: UnitLength.meters),
                         format: .measurement(width: .abbreviated, usage: .road))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(action: onEnd) {
                Text("End")
                    .font(.headline)
                    .padding(.horizontal, Theme.Spacing.s)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
        }
        .padding(Theme.Spacing.l)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}

private struct ArrivalCard: View {
    let title: String
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.l) {
            CategoryBadge(icon: .turnArrive, size: 52)
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer(minLength: 0)
            Button("Done", action: onDone)
                .buttonStyle(.glassProminent)
        }
        .padding(Theme.Spacing.l)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}
