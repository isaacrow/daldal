import CoreLocation
import Foundation
import MapLibre
import UIKit

/// Colours the chosen route itself by live traffic, like Waze: orange where it's slow, red where it's heavy,
/// dark red where it's standing still. The traffic comes from the live server's `/v1/traffic` GeoJSON.
enum RouteTraffic {
    static let layer = "route-traffic"

    /// A stretch of the route and how congested it is (1 slow, 2 heavy, 3 standstill).
    struct Stretch: Equatable {
        var level: Int
        var coordinates: [CLLocationCoordinate2D]

        static func == (a: Stretch, b: Stretch) -> Bool {
            a.level == b.level && a.coordinates.count == b.coordinates.count
        }
    }

    /// Walks the route in short steps and marks each step with the worst congestion within `match` metres.
    static func stretches(along route: [CLLocationCoordinate2D], traffic geojson: Data?, match: Double = 18) -> [Stretch] {
        guard route.count >= 2, let geojson, let lines = congestedLines(geojson), !lines.isEmpty else { return [] }

        // Congested roads as dense points in a coarse grid, so each route step looks only at its neighbours.
        let cell = 0.0005 // About 55 m.
        var grid: [Int64: [(CLLocationCoordinate2D, Int)]] = [:]
        func key(_ c: CLLocationCoordinate2D) -> Int64 {
            Int64((c.latitude / cell).rounded(.down)) * 10_000_000 + Int64((c.longitude / cell).rounded(.down))
        }
        for (coordinates, level) in lines {
            for point in densify(coordinates, every: 10) { grid[key(point), default: []].append((point, level)) }
        }

        func level(at point: CLLocationCoordinate2D) -> Int {
            let here = CLLocation(latitude: point.latitude, longitude: point.longitude)
            var worst = 0
            for dLat in -1...1 {
                for dLon in -1...1 {
                    let probe = CLLocationCoordinate2D(latitude: point.latitude + Double(dLat) * cell,
                                                       longitude: point.longitude + Double(dLon) * cell)
                    for (candidate, level) in grid[key(probe)] ?? [] where level > worst {
                        if CLLocation(latitude: candidate.latitude, longitude: candidate.longitude).distance(from: here) <= match {
                            worst = level
                        }
                    }
                }
            }
            return worst
        }

        var result: [Stretch] = []
        var current: Stretch?
        for point in densify(route, every: 12) {
            let level = level(at: point)
            if level > 0, current?.level == level {
                current?.coordinates.append(point)
            } else {
                if let finished = current, finished.coordinates.count >= 2 { result.append(finished) }
                // Start the next stretch at the last point so the colours join without a gap.
                let start = current.flatMap(\.coordinates.last).map { [$0, point] } ?? [point]
                current = level > 0 ? Stretch(level: level, coordinates: start) : nil
            }
        }
        if let finished = current, finished.coordinates.count >= 2 { result.append(finished) }
        return result
    }

    /// Draws the stretches over the route line (below street names). Pass none to clear.
    static func draw(_ stretches: [Stretch], in style: MLNStyle, above routeLayer: String?) {
        let features: [MLNPolylineFeature] = stretches.map { stretch in
            var coordinates = stretch.coordinates
            let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
            feature.attributes = ["level": stretch.level]
            return feature
        }
        let shape = MLNShapeCollectionFeature(shapes: features)
        if let source = style.source(withIdentifier: layer) as? MLNShapeSource {
            source.shape = shape
            return
        }
        let source = MLNShapeSource(identifier: layer, shape: shape, options: nil)
        style.addSource(source)
        let line = MLNLineStyleLayer(identifier: layer, source: source)
        line.lineColor = NSExpression(
            format: "TERNARY(level == 1, %@, TERNARY(level == 2, %@, %@))",
            UIColor(red: 0.98, green: 0.62, blue: 0.08, alpha: 1),
            UIColor(red: 0.90, green: 0.22, blue: 0.20, alpha: 1),
            UIColor(red: 0.56, green: 0.08, blue: 0.10, alpha: 1)
        )
        line.lineWidth = NSExpression(forConstantValue: 7)
        line.lineCap = NSExpression(forConstantValue: "round")
        line.lineJoin = NSExpression(forConstantValue: "round")
        if let routeLayer, let route = style.layer(withIdentifier: routeLayer) {
            style.insertLayer(line, above: route)
        } else if let car = style.layer(withIdentifier: UserCarLayer.layer) {
            style.insertLayer(line, below: car)
        } else {
            style.addLayer(line)
        }
    }

    // MARK: Helpers

    /// The congested lines in the traffic GeoJSON, with their level.
    private static func congestedLines(_ data: Data) -> [([CLLocationCoordinate2D], Int)]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return nil }
        var lines: [([CLLocationCoordinate2D], Int)] = []
        for feature in features {
            let level = ((feature["properties"] as? [String: Any])?["level"] as? NSNumber)?.intValue ?? 0
            guard level > 0, let geometry = feature["geometry"] as? [String: Any] else { continue }
            let parts: [[[Double]]] = switch geometry["type"] as? String {
            case "LineString": (geometry["coordinates"] as? [[Double]]).map { [$0] } ?? []
            case "MultiLineString": geometry["coordinates"] as? [[[Double]]] ?? []
            default: []
            }
            for part in parts {
                let coordinates = part.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
                if coordinates.count >= 2 { lines.append((coordinates, level)) }
            }
        }
        return lines
    }

    /// The path's points plus extra ones so no two are more than `step` metres apart.
    static func densify(_ path: [CLLocationCoordinate2D], every step: Double) -> [CLLocationCoordinate2D] {
        guard let first = path.first else { return [] }
        var points = [first]
        for (a, b) in zip(path, path.dropFirst()) {
            let length = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            let pieces = max(1, Int((length / step).rounded(.up)))
            for i in 1...pieces {
                let t = Double(i) / Double(pieces)
                points.append(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                     longitude: a.longitude + (b.longitude - a.longitude) * t))
            }
        }
        return points
    }
}
