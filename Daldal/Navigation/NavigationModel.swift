import AVFoundation
import Combine
import CoreLocation
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI
import Observation
import UIKit

/// Owns a trip from "Directions" to arrival: route options, the Ferrostar session, rerouting and voice.
@Observable
final class NavigationModel {
    enum Phase: Equatable {
        case idle
        case planning
        case preview
        case navigating
        case arrived
    }

    private(set) var phase: Phase = .idle
    private(set) var destination: Place?
    private(set) var routes: [Route] = []
    var selectedRouteIndex = 0
    private(set) var state: NavigationState?
    private(set) var speedLimit: Measurement<UnitSpeed>?
    private(set) var errorMessage: String?
    /// Whether the last route came from the phone (offline pack) or the server.
    private(set) var routedOnDevice = false
    /// Extra seconds of live traffic per route option (by index); empty without live data.
    private(set) var liveDelays: [Int: TimeInterval] = [:]
    /// A clearly faster route found while driving, waiting for the driver's yes or no.
    private(set) var fasterRoute: (route: Route, savings: TimeInterval)?
    /// A report the car just passed: "Still there?"
    private(set) var stillThere: LiveReport?

    var selectedRoute: Route? { routes.indices.contains(selectedRouteIndex) ? routes[selectedRouteIndex] : nil }

    /// A route's duration including live traffic, which is what options are compared on.
    func liveDuration(of index: Int) -> TimeInterval {
        guard routes.indices.contains(index) else { return 0 }
        return routes[index].expectedTravelTime + (liveDelays[index] ?? 0)
    }

    @ObservationIgnored let locationProvider: CoreLocationProvider
    @ObservationIgnored let voice: VoiceGuide
    @ObservationIgnored let live: LiveStore
    @ObservationIgnored private let probes = ProbeRecorder()
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var announcedReports: Set<String> = []
    @ObservationIgnored private var askedReports: Set<String> = []
    @ObservationIgnored private let routeProvider: DaldalRouteProvider
    @ObservationIgnored private let annotations = AnnotationPublisher<ValhallaExtendedOSRMAnnotation>.valhallaExtendedOSRM()
    @ObservationIgnored private var core: FerrostarCore!
    @ObservationIgnored private let coreDelegate = CoreDelegate()
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var planningTask: Task<Void, Never>?

    /// Tuned for Iraqi cities: GPS in Baghdad's dense blocks is often 20-30 m off.
    static let config = SwiftNavigationControllerConfig(
        waypointAdvance: .waypointWithinRange(100),
        stepAdvanceCondition: stepAdvanceDistanceEntryAndExit(
            distanceToEndOfStep: 30, distanceAfterEndOfStep: 5, minimumHorizontalAccuracy: 32
        ),
        arrivalStepAdvanceCondition: stepAdvanceDistanceToEndOfStep(distance: 25, minimumHorizontalAccuracy: 32),
        routeDeviationTracking: .staticThreshold(minimumHorizontalAccuracy: 30, maxAcceptableDeviation: 35),
        snappedLocationCourseFiltering: .snapToRoute
    )

    init(packs: OfflinePackManager, voice: VoiceGuide, live: LiveStore) {
        self.voice = voice
        self.live = live
        locationProvider = CoreLocationProvider(activityType: .automotiveNavigation, allowBackgroundLocationUpdates: true)
        routeProvider = DaldalRouteProvider(
            pack: { [weak packs] in packs?.installed },
            closures: { [weak live] in await live?.currentClosures() ?? [] }
        )
        core = FerrostarCore(
            customRouteProvider: routeProvider,
            locationProvider: locationProvider,
            navigationControllerConfig: Self.config,
            annotation: annotations,
            // Ferrostar's own speech is muted: it would read Valhalla's text. VoiceGuide speaks instead.
            spokenInstructionObserver: SpokenInstructionObserver(
                synthesizer: AVSpeechSynthesizer(), isMuted: true, managesAudioSession: false
            )
        )
        core.delegate = coreDelegate
        coreDelegate.config = Self.config

        core.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &subscriptions)
        annotations.$speedLimit
            .receive(on: DispatchQueue.main)
            .sink { [weak self] limit in self?.speedLimit = limit }
            .store(in: &subscriptions)
    }

    // MARK: Planning

    func planRoute(to place: Place, from location: CLLocation?) {
        planningTask?.cancel()
        destination = place
        routes = []
        selectedRouteIndex = 0
        errorMessage = nil
        phase = .planning

        planningTask = Task {
            guard let location = location ?? locationProvider.lastLocation?.clLocation else {
                errorMessage = String(localized: "Waiting for your location. Make sure Location is on for Daldal.")
                phase = .preview
                return
            }
            do {
                let found = try await core.getRoutes(
                    initialLocation: UserLocation(clLocation: location),
                    waypoints: [Waypoint(coordinate: GeographicCoordinate(cl: place.coordinate), kind: .break)]
                )
                guard !Task.isCancelled else { return }
                routedOnDevice = await routeProvider.lastSource == .device
                liveDelays = [:]
                routes = found
                if found.isEmpty { errorMessage = RoutingError.noRoute.errorDescription }
                await loadLiveDelays(for: found)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? RoutingError.server.errorDescription
            }
            phase = .preview
        }
    }

    func cancelPlanning() {
        planningTask?.cancel()
        routes = []
        destination = nil
        errorMessage = nil
        phase = .idle
    }

    // MARK: Driving

    func start() {
        guard let route = selectedRoute else { return }
        do {
            try core.startNavigation(route: route, config: Self.config)
            voice.begin(route: route, destinationName: destination?.name)
            UIApplication.shared.isIdleTimerDisabled = true // Never let the screen sleep mid-drive.
            phase = .navigating
            probes.begin()
            announcedReports = []
            askedReports = []
            startLiveLoop()
        } catch {
            errorMessage = RoutingError.server.errorDescription
        }
    }

    func stop() {
        core.stopNavigation()
        voice.end()
        probes.end()
        liveTask?.cancel()
        liveTask = nil
        fasterRoute = nil
        stillThere = nil
        liveDelays = [:]
        UIApplication.shared.isIdleTimerDisabled = false
        routes = []
        destination = nil
        state = nil
        phase = .idle
    }

    private func stateChanged(_ newState: NavigationState?) {
        state = newState
        guard phase == .navigating, let newState else { return }
        if case .complete = newState.tripState {
            probes.end()
            liveTask?.cancel()
            voice.arrived(destinationName: destination?.name)
            UIApplication.shared.isIdleTimerDisabled = false
            phase = .arrived
            return
        }
        if newState.isCalculatingNewRoute {
            voice.rerouting()
        } else if let route = core.route {
            voice.update(state: newState, route: route)
        }
        if let location = newState.preferredUserLocation?.clLocation {
            probes.record(location)
            checkReports(near: location, state: newState)
        }
    }

    // MARK: Live traffic and reports

    private func startLiveLoop() {
        liveTask?.cancel()
        guard live.isAvailable else { return }
        liveTask = Task {
            var lastFasterCheck = Date.now
            while !Task.isCancelled, phase == .navigating {
                if let here = state?.preferredUserLocation?.clLocation {
                    await live.refresh(around: here.coordinate)
                }
                if Date.now.timeIntervalSince(lastFasterCheck) >= 120 {
                    lastFasterCheck = .now
                    await checkForFasterRoute()
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Announces reports coming up on the route, and asks about ones just passed.
    private func checkReports(near location: CLLocation, state: NavigationState) {
        guard !live.reports.isEmpty, let steps = state.remainingSteps else { return }
        let path = steps.flatMap(\.geometry).map(\.coordinate2D)
        guard let here = RouteMath.distanceAlong(path, to: location.coordinate, maxOffset: 60) else { return }
        let speed = max(location.speed, 0)
        let warnAt = min(max(300, speed * 25), 1500) // About 25 s of warning, between 300 m and 1.5 km.

        for report in live.reports {
            guard let along = RouteMath.distanceAlong(path, to: report.coordinate, maxOffset: 35) else { continue }
            let ahead = along - here
            if ahead > 0, ahead <= warnAt, announcedReports.insert(report.id).inserted {
                voice.reportAhead(report.type, distance: ahead)
            } else if (-120 ... -15).contains(ahead), !live.handled.contains(report.id),
                      askedReports.insert(report.id).inserted {
                stillThere = report
                Task {
                    try? await Task.sleep(for: .seconds(12))
                    if stillThere?.id == report.id { stillThere = nil }
                }
            }
        }
    }

    func answerStillThere(_ yes: Bool) {
        guard let report = stillThere else { return }
        live.vote(report, stillThere: yes)
        stillThere = nil
    }

    private func loadLiveDelays(for routes: [Route]) async {
        guard let api = LiveAPI.shared, !routes.isEmpty else { return }
        let shapes = routes.enumerated().map { index, route in
            (id: String(index), polyline6: RouteMath.encodePolyline6(route.geometry.map(\.coordinate2D)))
        }
        guard let delays = try? await api.liveDelays(shapes) else { return }
        liveDelays = Dictionary(uniqueKeysWithValues: delays.compactMap { key, value in Int(key).map { ($0, value) } })
        // Default to the route that is fastest right now, not on an empty road.
        if let best = routes.indices.min(by: { liveDuration(of: $0) < liveDuration(of: $1) }) {
            selectedRouteIndex = best
        }
    }

    /// Waze's best trick: while driving, look for a route that is clearly faster given traffic and closures.
    private func checkForFasterRoute() async {
        guard phase == .navigating, fasterRoute == nil, let api = LiveAPI.shared, let destination,
              let state, let progress = state.currentProgress, let here = state.preferredUserLocation,
              let remaining = state.remainingSteps, progress.durationRemaining > 300 else { return }

        let currentPath = remaining.flatMap(\.geometry).map(\.coordinate2D)
        let waypoint = Waypoint(coordinate: GeographicCoordinate(cl: destination.coordinate), kind: .break)
        guard let candidates = try? await routeProvider.getRoutes(userLocation: here, waypoints: [waypoint]),
              !candidates.isEmpty else { return }

        var shapes = [(id: "current", polyline6: RouteMath.encodePolyline6(currentPath))]
        for (index, route) in candidates.enumerated() {
            shapes.append((id: String(index), polyline6: RouteMath.encodePolyline6(route.geometry.map(\.coordinate2D))))
        }
        let delays = (try? await api.liveDelays(shapes)) ?? [:]
        func eta(_ index: Int) -> TimeInterval { candidates[index].expectedTravelTime + (delays[String(index)] ?? 0) }
        guard let best = candidates.indices.min(by: { eta($0) < eta($1) }) else { return }
        let currentETA = progress.durationRemaining + (delays["current"] ?? 0)
        let savings = currentETA - eta(best)

        // Only worth interrupting a driver for a real gain, on a genuinely different road.
        let path = candidates[best].geometry.map(\.coordinate2D)
        guard savings >= max(120, currentETA * 0.1), RouteMath.overlap(path, with: currentPath) < 0.85,
              phase == .navigating else { return }
        let offered = candidates[best]
        fasterRoute = (offered, savings)
        voice.fasterRoute(saving: savings)
        Task {
            try? await Task.sleep(for: .seconds(20))
            if fasterRoute?.route == offered { fasterRoute = nil }
        }
    }

    func acceptFasterRoute() {
        guard let route = fasterRoute?.route else { return }
        fasterRoute = nil
        do {
            try core.startNavigation(route: route, config: Self.config)
            voice.routeChanged()
            announcedReports = []
        } catch {
            // Keep driving the current route; it's still valid.
        }
    }

    func dismissFasterRoute() {
        fasterRoute = nil
    }
}

/// Ferrostar's delegate: reroute on deviation and switch to the new route as soon as it loads.
///
/// nonisolated: Ferrostar calls these from its own background tasks (rerouting). Under the project's
/// main-actor default, a main-actor delegate makes Swift 6 trap at runtime the first time you leave the route.
nonisolated private final class CoreDelegate: FerrostarCoreDelegate {
    var config: SwiftNavigationControllerConfig?

    func core(_ core: FerrostarCore, didStartWith route: Route) {}

    func core(_ core: FerrostarCore, correctiveActionForDeviation deviation: DeviationKind,
              remainingWaypoints waypoints: [Waypoint]) -> CorrectiveAction {
        .getNewRoutes(waypoints: waypoints)
    }

    func core(_ core: FerrostarCore, loadedAlternateRoutes routes: [Route]) {
        guard core.state?.isCalculatingNewRoute == true, let route = routes.first else { return }
        try? core.startNavigation(route: route, config: config)
    }
}

extension GeographicCoordinate {
    var coordinate2D: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
}

extension Route {
    /// Sum of step durations, in seconds. Valhalla's route-level duration isn't exposed by the FFI type.
    var expectedTravelTime: TimeInterval { steps.reduce(0) { $0 + $1.duration } }
}
