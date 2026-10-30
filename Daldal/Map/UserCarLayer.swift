import CoreLocation
import MapLibre
import UIKit

/// The user's car drawn on the map as a 3D object (body + glass cabin) that turns with the direction of travel.
///
/// It is built from extruded footprints in the map itself, so it sits in the 3D scene with the buildings and tilts
/// with the camera. Drawn larger than life (about 24 m long) so it reads at street zoom, like a navigation arrow.
enum UserCarLayer {
    static let layer = "user-car"

    /// Footprints in metres, x to the right, y forward. Pointed nose, squared tail.
    private static let body: [(Double, Double)] = [(-5, -12), (5, -12), (5.4, 6), (3.6, 11), (0, 12.5), (-3.6, 11), (-5.4, 6)]
    private static let cabin: [(Double, Double)] = [(-3.9, -6), (3.9, -6), (4.1, 3.5), (2.6, 6.5), (-2.6, 6.5), (-4.1, 3.5)]

    static func update(in style: MLNStyle, at coordinate: CLLocationCoordinate2D, heading: CLLocationDirection) {
        let features = [
            footprint(body, at: coordinate, heading: heading, base: 0, top: 4.2, part: "body"),
            footprint(cabin, at: coordinate, heading: heading, base: 4.2, top: 7.4, part: "cabin"),
        ]
        let shape = MLNShapeCollectionFeature(shapes: features)
        if let source = style.source(withIdentifier: layer) as? MLNShapeSource {
            source.shape = shape
            return
        }
        let source = MLNShapeSource(identifier: layer, shape: shape, options: nil)
        style.addSource(source)
        let car = MLNFillExtrusionStyleLayer(identifier: layer, source: source)
        car.fillExtrusionColor = NSExpression(
            format: "TERNARY(part == 'cabin', %@, %@)",
            UIColor(red: 0.10, green: 0.16, blue: 0.20, alpha: 1),
            UIColor(named: "AccentColor") ?? .systemTeal
        )
        car.fillExtrusionBase = NSExpression(forKeyPath: "base")
        car.fillExtrusionHeight = NSExpression(forKeyPath: "top")
        car.fillExtrusionOpacity = NSExpression(forConstantValue: 1)
        car.fillExtrusionHasVerticalGradient = NSExpression(forConstantValue: true)
        style.addLayer(car) // Above everything: you should never lose your own car behind a building.
    }

    static func remove(from style: MLNStyle) {
        (style.source(withIdentifier: layer) as? MLNShapeSource)?.shape = nil
    }

    private static func footprint(_ points: [(Double, Double)], at c: CLLocationCoordinate2D, heading: CLLocationDirection,
                                  base: Double, top: Double, part: String) -> MLNPolygonFeature {
        let angle = heading * .pi / 180
        let metresPerDegreeLon = 111_320 * cos(c.latitude * .pi / 180)
        var ring = points.map { x, y -> CLLocationCoordinate2D in
            // Rotate the local frame so +y points along the heading (0 = north, clockwise).
            let east = x * cos(angle) + y * sin(angle)
            let north = -x * sin(angle) + y * cos(angle)
            return CLLocationCoordinate2D(latitude: c.latitude + north / 111_320, longitude: c.longitude + east / metresPerDegreeLon)
        }
        ring.append(ring[0])
        let feature = MLNPolygonFeature(coordinates: &ring, count: UInt(ring.count))
        feature.attributes = ["base": base, "top": top, "part": part]
        return feature
    }
}
