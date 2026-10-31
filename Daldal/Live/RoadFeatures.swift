import CoreLocation
import Foundation
import MapLibre
import Observation
import UIKit

/// A fixed thing on the road the driver should know about, from OpenStreetMap.
nonisolated struct RoadFeature: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case speedCamera, stopSign, trafficSignals

        var icon: DaldalIcon {
            switch self {
            case .speedCamera: .camera
            case .stopSign: .stopSign
            case .trafficSignals: .reportLight
            }
        }

        /// How far ahead it's announced, in metres.
        var warnDistance: Double {
            switch self {
            case .speedCamera: 400
            case .stopSign: 150
            case .trafficSignals: 0 // Drawn, not announced: there are too many.
            }
        }
    }

    let id: Int64
    let kind: Kind
    let coordinate: CLLocationCoordinate2D
    /// Camera speed limit in km/h, when tagged.
    let maxSpeed: Int?

    static func == (a: RoadFeature, b: RoadFeature) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Speed cameras, stop signs and traffic lights around the driver, refreshed as they move.
/// Coverage is whatever OpenStreetMap mappers have recorded in Iraq, which is still patchy for cameras.
@Observable
final class RoadFeatureStore {
    private(set) var features: [RoadFeature] = []

    @ObservationIgnored private var fetchedAround: CLLocation?
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var announced: Set<Int64> = []

    /// Fetches features within 6 km, unless we already have the area (moved less than 3 km).
    func refresh(around coordinate: CLLocationCoordinate2D) async {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let fetchedAround, fetchedAround.distance(from: here) < 3_000 { return }
        guard !fetching, Region.contains(coordinate) else { return }
        fetching = true
        defer { fetching = false }
        let around = "(around:6000,\(coordinate.latitude),\(coordinate.longitude))"
        let query = "[out:json][timeout:20];(node[highway=speed_camera]\(around);node[highway=stop]\(around);"
            + "node[highway=traffic_signals]\(around););out 400;"
        guard let elements = try? await Overpass.run(query) else { return }
        features = elements.compactMap { element in
            guard let coordinate = element.coordinate else { return nil }
            let kind: RoadFeature.Kind = switch element.tags?["highway"] {
            case "speed_camera": .speedCamera
            case "stop": .stopSign
            default: .trafficSignals
            }
            let speed = element.tags?["maxspeed"].flatMap { Int($0.filter(\.isNumber)) }
            return RoadFeature(id: element.id, kind: kind, coordinate: coordinate, maxSpeed: speed)
        }
        fetchedAround = here
    }

    /// The next camera or stop sign on the route ahead within its warning distance, once per feature.
    func nextWarning(on route: [CLLocationCoordinate2D], travelled: Double) -> RoadFeature? {
        guard route.count >= 2 else { return nil }
        for feature in features where feature.kind.warnDistance > 0 && !announced.contains(feature.id) {
            guard let along = RouteMath.distanceAlong(route, to: feature.coordinate, maxOffset: 25) else { continue }
            let ahead = along - travelled
            if ahead > 0, ahead <= feature.kind.warnDistance {
                announced.insert(feature.id)
                return feature
            }
        }
        return nil
    }

    // MARK: Map

    static let layer = "road-features"

    /// Draws the features as small signs that appear from street zoom.
    static func draw(_ features: [RoadFeature], in style: MLNStyle) {
        let points = features.filter { $0.kind != .trafficSignals }.map { feature in
            let point = MLNPointFeature()
            point.coordinate = feature.coordinate
            point.attributes = ["icon": "road-\(feature.kind.rawValue)", "kind": feature.kind.rawValue]
            return point
        }
        let shape = MLNShapeCollectionFeature(shapes: points)
        if let source = style.source(withIdentifier: layer) as? MLNShapeSource {
            source.shape = shape
            return
        }
        for kind in [RoadFeature.Kind.speedCamera, .stopSign, .trafficSignals] {
            style.setImage(sign(kind), forName: "road-\(kind.rawValue)")
        }
        let source = MLNShapeSource(identifier: layer, shape: shape, options: nil)
        style.addSource(source)
        let symbols = MLNSymbolStyleLayer(identifier: layer, source: source)
        symbols.iconImageName = NSExpression(forKeyPath: "icon")
        symbols.iconAllowsOverlap = NSExpression(forConstantValue: true)
        symbols.iconScale = NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
                                         [13: 0.6, 17: 1.0])
        symbols.minimumZoomLevel = 13
        style.addLayer(symbols)
    }

    private static func sign(_ kind: RoadFeature.Kind) -> UIImage {
        let size: CGFloat = 26
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let rect = CGRect(x: 1, y: 1, width: size - 2, height: size - 2)
            let shape: UIBezierPath
            let fill: UIColor
            switch kind {
            case .stopSign:
                // An octagon, like the real sign.
                shape = UIBezierPath()
                for k in 0..<8 {
                    let angle = CGFloat(k) * .pi / 4 + .pi / 8
                    let point = CGPoint(x: rect.midX + cos(angle) * rect.width / 2, y: rect.midY + sin(angle) * rect.height / 2)
                    k == 0 ? shape.move(to: point) : shape.addLine(to: point)
                }
                shape.close()
                fill = UIColor(red: 0.80, green: 0.10, blue: 0.12, alpha: 1)
            case .speedCamera:
                shape = UIBezierPath(roundedRect: rect, cornerRadius: 6)
                fill = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
            case .trafficSignals:
                shape = UIBezierPath(ovalIn: rect)
                fill = UIColor(white: 0.25, alpha: 1)
            }
            fill.setFill()
            shape.fill()
            UIColor.white.setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
            UIImage(named: kind.icon.assetName)?.withTintColor(.white).draw(in: rect.insetBy(dx: 5, dy: 5))
        }
    }
}
