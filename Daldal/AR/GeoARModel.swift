import ARKit
import AVFoundation
import Combine
import CoreLocation
import Observation
import RealityKit
import UIKit

/// Places a heritage site in the camera view using GPS + compass.
///
/// Apple's `ARGeoTrackingConfiguration` (visual positioning) only works in a list of supported cities,
/// and Iraq isn't one of them, so we anchor with our own method:
/// 1. Run world tracking with `.gravityAndHeading`, so the AR frame is aligned to true north.
/// 2. When GPS is accurate enough, convert the site's coordinate to an east/north offset from the user.
/// 3. Re-anchor whenever GPS gets clearly better, which corrects the drift of both systems.
/// The user can fine-tune the remaining compass error by dragging sideways.
@Observable
final class GeoARModel {
    enum Status: Equatable {
        case unsupported, cameraDenied, waitingForLocation
        case poorAccuracy(meters: Int)
        case tooFast
        case placed
    }

    let site: HeritageSite
    let languageCode: String
    private(set) var status: Status = .waitingForLocation
    private(set) var distance: CLLocationDistance?
    /// Site direction relative to where the camera points, in degrees (-180...180). 0 = straight ahead.
    private(set) var relativeBearing: Double?
    private(set) var isLoadingModel = false
    /// Manual compass correction from the drag gesture, in degrees.
    var headingCorrection: Double = 0 {
        didSet { applyHeadingCorrection() }
    }

    /// GPS must be at least this good before we place anything.
    static let requiredAccuracy: CLLocationAccuracy = 25

    /// How good GPS must be before placing the site. Close up, metres matter; from far away they don't:
    /// 60 m of error seen from 2 km is under 2 degrees. Indoors and between buildings, GPS rarely beats 30 m.
    static func accuracyNeeded(atDistance distance: CLLocationDistance) -> CLLocationAccuracy {
        switch distance {
        case ..<300: requiredAccuracy
        case ..<1_000: 40
        case ..<5_000: 65
        default: 100
        }
    }
    /// Walking pace or slower. AR is never shown to a driver.
    static let maxSpeed: CLLocationSpeed = 4
    /// Approximate camera height above the ground when holding a phone.
    static let eyeHeight: Float = 1.5
    /// Labels and markers are drawn at a constant on-screen size as if they were this far away.
    static let labelReferenceDistance: Float = 120

    @ObservationIgnored private weak var arView: ARView?
    @ObservationIgnored private var root: AnchorEntity?
    @ObservationIgnored private let modelHolder = Entity()
    @ObservationIgnored private let marker = Entity()
    @ObservationIgnored private let label = Entity()
    @ObservationIgnored private var labelDistanceBucket = -1
    @ObservationIgnored private var placedAccuracy: CLLocationAccuracy = .infinity
    @ObservationIgnored private var placedAt = Date.distantPast
    @ObservationIgnored private var lastLocation: CLLocation?
    @ObservationIgnored private var updateSubscription: (any Cancellable)?
    @ObservationIgnored private var lastBearingUpdate = Date.distantPast

    init(site: HeritageSite, languageCode: String) {
        self.site = site
        self.languageCode = languageCode
    }

    // MARK: Lifecycle

    func start(in view: ARView) {
        arView = view
        guard ARWorldTrackingConfiguration.isSupported else { status = .unsupported; return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .denied { status = .cameraDenied; return }

        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        config.environmentTexturing = .automatic
        // Real depth: on LiDAR phones, the scanned mesh hides the model behind real walls and people.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            view.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        view.session.run(config)
        ARCameraWatchdog.watch(view.session, configuration: config)

        updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.updateRelativeBearing()
        }

        buildMarker()
        Task { await loadModelIfAvailable() }
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
        distance = site.location.distance(from: location)
        guard arView != nil, status != .unsupported, status != .cameraDenied else { return }

        if location.speed > Self.maxSpeed {
            status = .tooFast
            root?.isEnabled = false
            return
        }
        let needed = Self.accuracyNeeded(atDistance: site.location.distance(from: location))
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= needed else {
            if root == nil { status = .poorAccuracy(meters: Int(location.horizontalAccuracy.rounded())) }
            return
        }

        let muchBetter = location.horizontalAccuracy < placedAccuracy * 0.7
        let stale = Date.now.timeIntervalSince(placedAt) > 20
        if root == nil || muchBetter || stale {
            place(from: location)
        } else {
            updateLabel()
        }
        root?.isEnabled = true
        status = .placed
    }

    private func place(from location: CLLocation) {
        guard let arView else { return }
        placedAccuracy = location.horizontalAccuracy
        placedAt = .now

        // Anchor on the ground under the user, then put the site at its real offset from there.
        var ground = arView.cameraTransform.translation
        ground.y -= Self.eyeHeight
        let anchor = AnchorEntity(world: ground)

        let offset = GeoMath.eastNorth(from: location.coordinate, to: site.coordinate)
        let placement = GeoMath.displayPlacement(offset: offset, maxDistance: Double(Self.labelReferenceDistance))
        let shownDistance = min(Float(simd_length(offset)), Self.labelReferenceDistance)
        let screenScale = max(shownDistance, 8) / Self.labelReferenceDistance

        // The real model keeps true apparent size; marker and label keep a readable size at any distance.
        modelHolder.position = placement.position
        modelHolder.scale = SIMD3(repeating: placement.scale)
        marker.position = placement.position
        marker.scale = SIMD3(repeating: screenScale)
        label.position = placement.position + SIMD3(0, 34 * screenScale, 0)
        label.scale = SIMD3(repeating: screenScale)

        for child in [modelHolder, marker, label] { anchor.addChild(child) }
        if let root { arView.scene.removeAnchor(root) }
        arView.scene.addAnchor(anchor)
        root = anchor
        applyHeadingCorrection()
        updateLabel()
    }

    private func applyHeadingCorrection() {
        root?.orientation = simd_quatf(angle: Float(-headingCorrection * .pi / 180), axis: [0, 1, 0])
    }

    private func updateRelativeBearing() {
        // Four times a second is plenty for an on-screen arrow.
        guard Date.now.timeIntervalSince(lastBearingUpdate) > 0.25,
              let arView, let lastLocation else { return }
        lastBearingUpdate = .now
        let forward = -arView.cameraTransform.matrix.columns.2
        let cameraHeading = atan2(Double(forward.x), Double(-forward.z)) * 180 / .pi
        let siteBearing = GeoMath.bearing(from: lastLocation.coordinate, to: site.coordinate) + headingCorrection
        var delta = (siteBearing - cameraHeading).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        relativeBearing = delta
    }

    // MARK: Content

    /// A slim light column that marks the site until (or unless) a real model is available.
    private func buildMarker() {
        let accent = UIColor(named: "AccentColor") ?? .systemTeal
        let column = ModelEntity(
            mesh: .generateCylinder(height: 30, radius: 0.5),
            materials: [UnlitMaterial(color: accent.withAlphaComponent(0.75))]
        )
        column.position.y = 15
        let base = ModelEntity(
            mesh: .generateCylinder(height: 0.2, radius: 3),
            materials: [UnlitMaterial(color: accent.withAlphaComponent(0.35))]
        )
        marker.children.removeAll()
        marker.addChild(column)
        marker.addChild(base)
        label.components.set(BillboardComponent())
    }

    private func updateLabel() {
        guard let distance else { return }
        // Rebuilding a text mesh is not free; only do it when the shown number changes.
        let bucket = Int(distance / 10)
        guard bucket != labelDistanceBucket else { return }
        labelDistanceBucket = bucket

        let measured = Measurement(value: distance, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
        let text = "\(site.name(languageCode: languageCode))\n\(measured)"
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.05,
            font: .systemFont(ofSize: 4, weight: .bold),
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        let bounds = mesh.bounds
        entity.position = SIMD3(-bounds.center.x, -bounds.min.y, 0)
        label.children.removeAll()
        label.addChild(entity)
    }

    private func loadModelIfAvailable() async {
        guard let remote = site.modelURL else { return }
        isLoadingModel = true
        defer { isLoadingModel = false }
        do {
            let local = try await ModelCache.localURL(for: remote, id: site.id)
            let model = try await Entity(contentsOf: local)
            // USDZ models are authored in metres; generated ones are 1 unit tall and scaled to the real height.
            if let height = site.modelHeight { model.scale = SIMD3(repeating: Float(height)) }
            let bounds = model.visualBounds(relativeTo: modelHolder)
            model.position.y -= bounds.min.y
            modelHolder.children.removeAll()
            modelHolder.addChild(model)
            marker.isEnabled = false
        } catch {
            // Keep the marker; the site is still found and labelled.
        }
    }
}

/// Downloads USDZ models once and keeps them in Caches.
enum ModelCache {
    static func localURL(for remote: URL, id: String) async throws -> URL {
        let dir = try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "ARModels", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(id).usdz")
        if FileManager.default.fileExists(atPath: file.path()) { return file }

        let (temp, response) = try await URLSession.shared.download(from: remote)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
            throw URLError(.badServerResponse)
        }
        try FileManager.default.moveItem(at: temp, to: file)
        return file
    }
}
