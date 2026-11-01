import CoreLocation
import CoreMotion
import Foundation
import MapLibre
import Observation
import UIKit

/// A rough spot on the road (pothole, broken patch, unmarked bump) felt by the phone while driving.
nonisolated struct RoughSpot: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var latitude: Double
    var longitude: Double
    /// How many separate times a jolt was felt here.
    var hits: Int
    /// The strongest jolt, in g.
    var strength: Double
    var lastSeen: Date
    /// Sent to the live server as a pothole report (once it's hit twice).
    var shared = false

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// The automatic pothole map: jolts felt while driving, merged by place and kept on the phone.
@Observable
final class RoughRoadStore {
    private(set) var spots: [RoughSpot] = []

    /// Jolts within this distance count as the same spot (GPS while driving is good to ~10 m).
    static let mergeRadius: CLLocationDistance = 20
    /// Spots not felt again for this long fade away (roads get repaired).
    static let forgetAfter: TimeInterval = 60 * 86_400

    @ObservationIgnored private let file: URL = {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return folder.appending(path: "rough-spots.json")
    }()

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([RoughSpot].self, from: data) {
            spots = saved.filter { Date.now.timeIntervalSince($0.lastSeen) < Self.forgetAfter }
        }
    }

    /// Adds a jolt felt at `location`; merges it into a spot already there. Returns the spot.
    @discardableResult
    func record(at location: CLLocation, strength: Double) -> RoughSpot {
        if let index = spots.firstIndex(where: {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: location) <= Self.mergeRadius
        }) {
            var spot = spots[index]
            // Average the position over hits: each GPS fix is a little off.
            let n = Double(spot.hits)
            spot.latitude = (spot.latitude * n + location.coordinate.latitude) / (n + 1)
            spot.longitude = (spot.longitude * n + location.coordinate.longitude) / (n + 1)
            spot.hits += 1
            spot.strength = max(spot.strength, strength)
            spot.lastSeen = .now
            spots[index] = spot
            save()
            return spot
        }
        let spot = RoughSpot(id: UUID(), latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                             hits: 1, strength: strength, lastSeen: .now)
        spots.append(spot)
        save()
        return spot
    }

    func markShared(_ id: UUID) {
        guard let index = spots.firstIndex(where: { $0.id == id }) else { return }
        spots[index].shared = true
        save()
    }

    func clear() {
        spots = []
        save()
    }

    private func save() {
        try? JSONEncoder().encode(spots).write(to: file, options: .atomic)
    }

    // MARK: Map

    static let layer = "rough-spots"

    /// Orange dots on the road, bigger and stronger the more often a spot was felt.
    static func draw(_ spots: [RoughSpot], in style: MLNStyle) {
        let features = spots.map { spot in
            let point = MLNPointFeature()
            point.coordinate = spot.coordinate
            point.attributes = ["hits": min(spot.hits, 5)]
            return point
        }
        let shape = MLNShapeCollectionFeature(shapes: features)
        if let source = style.source(withIdentifier: layer) as? MLNShapeSource {
            source.shape = shape
            return
        }
        let source = MLNShapeSource(identifier: layer, shape: shape, options: nil)
        style.addSource(source)
        let dots = MLNCircleStyleLayer(identifier: layer, source: source)
        dots.circleColor = NSExpression(forConstantValue: UIColor(red: 0.95, green: 0.55, blue: 0.10, alpha: 1))
        dots.circleOpacity = NSExpression(format: "TERNARY(hits >= 2, 0.95, 0.6)")
        dots.circleRadius = NSExpression(
            format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
            [12: NSExpression(format: "1.5 + hits * 0.5"), 17: NSExpression(format: "4 + hits * 1.5")])
        dots.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
        dots.circleStrokeWidth = NSExpression(forConstantValue: 1.2)
        dots.minimumZoomLevel = 12
        style.addLayer(dots)
    }
}

/// Feels for jolts while driving: the motion sensors' acceleration along gravity (so it works however the phone is
/// mounted), counted only at driving speed so parking, walking and handling the phone don't count.
@MainActor
final class PotholeDetector {
    /// A sharp vertical jolt, well above normal road texture (about 0.1-0.2 g).
    static let threshold = 0.5
    /// Below about 15 km/h, bumps are speed humps, kerbs or parking, not the road surface.
    static let minimumSpeed: CLLocationSpeed = 4.2

    private let motion = CMMotionManager()
    private var lastJolt = Date.distantPast

    /// `location` gives the car's current fix; `onJolt` gets each detection with its strength in g.
    func start(location: @escaping () -> CLLocation?, onJolt: @escaping (CLLocation, Double) -> Void) {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 50
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            MainActor.assumeIsolated {
                guard let self, let jolt = Self.verticalJolt(data), jolt > Self.threshold,
                      Date.now.timeIntervalSince(self.lastJolt) > 1.5,
                      let here = location(), here.speed >= Self.minimumSpeed,
                      here.horizontalAccuracy >= 0, here.horizontalAccuracy < 30 else { return }
                self.lastJolt = .now
                onJolt(here, jolt)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    /// Acceleration along gravity (up and down), in g.
    nonisolated static func verticalJolt(_ data: CMDeviceMotion) -> Double? {
        let g = data.gravity, a = data.userAcceleration
        let length = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard length > 0.5 else { return nil }
        let along: Double = (a.x * g.x + a.y * g.y + a.z * g.z) / length
        return abs(along)
    }
}
