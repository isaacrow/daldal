import ARKit
import AVFoundation
import Combine
import CoreLocation
@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI
import Observation
import RealityKit
import UIKit

/// Walking directions drawn on the ground in AR: chevrons along the route, a floating arrow at each turn,
/// and a light column at the destination.
///
/// Anchoring works like the heritage AR (true-north world tracking + GPS), with one extra trick: the user
/// is snapped onto the route, and the path is drawn relative to that snapped point. So the chevrons always
/// start at the user's feet and follow the street's real shape, even when GPS itself is 10–20 m off.
@Observable
final class WalkARModel {
    enum Status: Equatable {
        case routing
        case noRoute(String)
        case unsupported, cameraDenied
        case waitingForGPS(meters: Int)
        case tooFast
        case guiding
        case arrived
    }

    let destination: Place
    private(set) var status: Status = .routing
    private(set) var nextManeuver: Maneuver?
    private(set) var distanceToManeuver: Double?
    private(set) var distanceRemaining: Double?
    /// Where the path continues, relative to where the camera points (-180...180). For the edge arrow.
    private(set) var relativeBearing: Double?
    var headingCorrection: Double = 0 {
        didSet { root?.orientation = simd_quatf(angle: Float(-headingCorrection * .pi / 180), axis: [0, 1, 0]) }
    }

    static let drawAhead: Double = 120 // metres of path shown in front of the user
    static let chevronSpacing: Double = 4
    static let offRouteDistance: Double = 45
    static let eyeHeight: Float = 1.5

    @ObservationIgnored private let provider: DaldalRouteProvider
    @ObservationIgnored private let voice: VoiceGuide
    @ObservationIgnored private let phraser = ManeuverPhraser(languageCode: AppLanguage.code)
    @ObservationIgnored private weak var arView: ARView?
    @ObservationIgnored private var root: AnchorEntity?
    @ObservationIgnored private var chevrons: [Entity] = []
    @ObservationIgnored private let turnMarker = Entity()
    @ObservationIgnored private let turnLabel = Entity()
    @ObservationIgnored private let goalMarker = Entity()
    @ObservationIgnored private var route: Route?
    @ObservationIgnored private var path: [CLLocationCoordinate2D] = []
    /// Distance along `path` at which each step's maneuver happens (the end of each step).
    @ObservationIgnored private var maneuverPoints: [(along: Double, maneuver: Maneuver)] = []
    @ObservationIgnored private var lastLocation: CLLocation?
    @ObservationIgnored private var lastAlong: Double = 0
    @ObservationIgnored private var lastPlaced = Date.distantPast
    @ObservationIgnored private var lastRouting = Date.distantPast
    @ObservationIgnored private var spoken: Set<String> = []
    @ObservationIgnored private var labelKey = ""
    @ObservationIgnored private var updateSubscription: (any Cancellable)?
    @ObservationIgnored private var lastBearingUpdate = Date.distantPast

    init(destination: Place, provider: DaldalRouteProvider, voice: VoiceGuide) {
        self.destination = destination
        self.provider = provider
        self.voice = voice
    }

    // MARK: Lifecycle

    func start(in view: ARView) {
        arView = view
        guard ARWorldTrackingConfiguration.isSupported else { status = .unsupported; return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .denied { status = .cameraDenied; return }

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        // Real depth on LiDAR phones: people and walls in front hide the arrows, as they would a real sign.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            view.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        view.session.run(config)
        ARCameraWatchdog.watch(view.session, configuration: config)
        buildEntities()
        updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.updateRelativeBearing()
        }
        if let lastLocation { update(location: lastLocation) }
    }

    func stop() {
        updateSubscription?.cancel()
        updateSubscription = nil
        arView?.session.pause()
    }

    // MARK: Location

    func update(location: CLLocation) {
        lastLocation = location
        guard status != .unsupported, status != .cameraDenied, status != .arrived else { return }
        if route == nil {
            requestRoute(from: location)
            return
        }
        if location.speed > 4 {
            status = .tooFast
            root?.isEnabled = false
            return
        }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 35 else {
            if root == nil { status = .waitingForGPS(meters: Int(location.horizontalAccuracy.rounded())) }
            return
        }

        // Where on the route the user is. Too far off: find a new walking route from here.
        guard let along = RouteMath.distanceAlong(path, to: location.coordinate, maxOffset: Self.offRouteDistance) else {
            if Date.now.timeIntervalSince(lastRouting) > 15 { requestRoute(from: location) }
            return
        }
        lastAlong = along
        let total = RouteMath.length(path)
        distanceRemaining = max(0, total - along)
        if total - along < 15 {
            status = .arrived
            root?.isEnabled = false
            voice.announce(phraser.arrived(at: destination.name), interrupt: true)
            return
        }

        let upcoming = maneuverPoints.first { $0.along > along + 3 }
        nextManeuver = upcoming?.maneuver
        distanceToManeuver = upcoming.map { $0.along - along }
        speakIfNeeded(upcoming, distance: distanceToManeuver)

        status = .guiding
        root?.isEnabled = true
        // Redraw when the user has moved a little, or at least every two seconds.
        if Date.now.timeIntervalSince(lastPlaced) > 2 || root == nil {
            place(along: along, upcoming: upcoming)
        }
    }

    private func requestRoute(from location: CLLocation) {
        lastRouting = .now
        status = route == nil ? .routing : status
        let waypoint = Waypoint(coordinate: GeographicCoordinate(cl: destination.coordinate), kind: .break)
        Task {
            do {
                let routes = try await provider.getRoutes(userLocation: UserLocation(clLocation: location),
                                                           waypoints: [waypoint], profile: .pedestrian)
                guard let first = routes.first else { throw RoutingError.noRoute }
                adopt(first)
                if let lastLocation { update(location: lastLocation) }
            } catch {
                if route == nil {
                    status = .noRoute((error as? LocalizedError)?.errorDescription ?? RoutingError.server.errorDescription ?? "")
                }
            }
        }
    }

    private func adopt(_ newRoute: Route) {
        route = newRoute
        path = newRoute.geometry.map(\.coordinate2D)
        spoken = []
        var along = 0.0
        maneuverPoints = []
        for (index, step) in newRoute.steps.enumerated() {
            along += step.distance
            let next = newRoute.steps.indices.contains(index + 1) ? newRoute.steps[index + 1] : nil
            if let maneuver = Maneuver(step: step, next: next) {
                maneuverPoints.append((along, maneuver))
            }
        }
    }

    private func speakIfNeeded(_ upcoming: (along: Double, maneuver: Maneuver)?, distance: Double?) {
        guard let upcoming, let distance else { return }
        let key = "\(Int(upcoming.along))"
        // Walking pace: a heads-up at ~40 m, and the instruction itself at ~10 m.
        if distance < 12, spoken.insert(key + "-now").inserted {
            voice.announce(phraser.spoken(upcoming.maneuver, distance: nil), interrupt: true)
        } else if distance < 45, distance > 20, spoken.insert(key + "-soon").inserted {
            voice.announce(phraser.spoken(upcoming.maneuver, distance: distance))
        }
    }

    // MARK: Drawing

    private func place(along: Double, upcoming: (along: Double, maneuver: Maneuver)?) {
        guard let arView, let origin = RouteMath.coordinate(along: path, at: along) else { return }
        lastPlaced = .now

        var ground = arView.cameraTransform.translation
        ground.y -= Self.eyeHeight
        let anchor = AnchorEntity(world: ground)

        func local(_ c: CLLocationCoordinate2D, lift: Float = 0.04) -> SIMD3<Float> {
            let offset = GeoMath.eastNorth(from: origin, to: c)
            return SIMD3(Float(offset.x), lift, Float(-offset.y))
        }

        // Chevrons every few metres along the path ahead, each pointing the way to walk.
        let end = min(along + Self.drawAhead, RouteMath.length(path))
        for (index, chevron) in chevrons.enumerated() {
            let d = along + 2 + Double(index) * Self.chevronSpacing
            guard d < end, let here = RouteMath.coordinate(along: path, at: d),
                  let ahead = RouteMath.coordinate(along: path, at: d + 1) else {
                chevron.isEnabled = false
                continue
            }
            let a = local(here), b = local(ahead)
            let dir = b - a
            chevron.position = a
            chevron.orientation = simd_quatf(angle: atan2(-dir.x, -dir.z), axis: [0, 1, 0])
            // Fade with distance so the nearest arrows read strongest.
            chevron.scale = SIMD3(repeating: Float(max(0.6, 1.2 - (d - along) / Self.drawAhead)))
            chevron.isEnabled = true
            anchor.addChild(chevron)
        }

        if let upcoming, upcoming.along - along < Self.drawAhead,
           let point = RouteMath.coordinate(along: path, at: upcoming.along),
           let after = RouteMath.coordinate(along: path, at: upcoming.along + 6) {
            let p = local(point, lift: 2.2), q = local(after, lift: 2.2)
            let dir = q - p
            turnMarker.position = p
            turnMarker.orientation = simd_quatf(angle: atan2(-dir.x, -dir.z), axis: [0, 1, 0])
            turnMarker.isEnabled = true
            turnLabel.position = p + SIMD3(0, 1.0, 0)
            updateTurnLabel(upcoming.maneuver, distance: upcoming.along - along)
            turnLabel.isEnabled = true
            anchor.addChild(turnMarker)
            anchor.addChild(turnLabel)
        } else {
            turnMarker.isEnabled = false
            turnLabel.isEnabled = false
        }

        if let last = path.last, RouteMath.length(path) - along < Self.drawAhead {
            goalMarker.position = local(last, lift: 0)
            goalMarker.isEnabled = true
            anchor.addChild(goalMarker)
        } else {
            goalMarker.isEnabled = false
        }

        if let root { arView.scene.removeAnchor(root) }
        arView.scene.addAnchor(anchor)
        root = anchor
        anchor.orientation = simd_quatf(angle: Float(-headingCorrection * .pi / 180), axis: [0, 1, 0])
    }

    private func buildEntities() {
        let accent = UIColor(named: "AccentColor") ?? .systemTeal
        let material = UnlitMaterial(color: accent.withAlphaComponent(0.9))
        // A flat "V" on the ground, pointing forward (-z): two thin bars at ±35°.
        func chevron(scale: Float = 1) -> Entity {
            let entity = Entity()
            for side: Float in [-1, 1] {
                let bar = ModelEntity(mesh: .generateBox(width: 0.08 * scale, height: 0.015, depth: 0.5 * scale, cornerRadius: 0.007),
                                      materials: [material])
                bar.position = SIMD3(side * 0.13 * scale, 0, 0.1 * scale)
                bar.orientation = simd_quatf(angle: side * 0.61, axis: [0, 1, 0])
                entity.addChild(bar)
            }
            return entity
        }
        chevrons = (0..<Int(Self.drawAhead / Self.chevronSpacing)).map { _ in chevron() }

        // The turn arrow: a big chevron standing up, so it reads from far away.
        let big = chevron(scale: 3)
        big.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        turnMarker.children.removeAll()
        turnMarker.addChild(big)
        turnLabel.components.set(BillboardComponent())

        let column = ModelEntity(mesh: .generateCylinder(height: 12, radius: 0.35),
                                 materials: [UnlitMaterial(color: accent.withAlphaComponent(0.7))])
        column.position.y = 6
        goalMarker.children.removeAll()
        goalMarker.addChild(column)
    }

    private func updateTurnLabel(_ maneuver: Maneuver, distance: Double) {
        let text = "\(phraser.action(maneuver))\n\(phraser.spokenDistance(distance))"
        guard text != labelKey else { return }
        labelKey = text
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.02, font: .systemFont(ofSize: 0.45, weight: .bold),
                                             alignment: .center, lineBreakMode: .byWordWrapping)
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        entity.position = SIMD3(-mesh.bounds.center.x, 0, 0)
        turnLabel.children.removeAll()
        turnLabel.addChild(entity)
    }

    private func updateRelativeBearing() {
        guard Date.now.timeIntervalSince(lastBearingUpdate) > 0.25, let arView, status == .guiding,
              let here = RouteMath.coordinate(along: path, at: lastAlong),
              let ahead = RouteMath.coordinate(along: path, at: lastAlong + 15) else { return }
        lastBearingUpdate = .now
        let forward = -arView.cameraTransform.matrix.columns.2
        let cameraHeading = atan2(Double(forward.x), Double(-forward.z)) * 180 / .pi
        var delta = (GeoMath.bearing(from: here, to: ahead) + headingCorrection - cameraHeading).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        relativeBearing = delta
    }
}
