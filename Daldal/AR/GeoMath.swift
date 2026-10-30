import CoreLocation
import simd

/// Converts between GPS coordinates and the local metric frame ARKit uses with `.gravityAndHeading`:
/// +x is east, +y is up, -z is true north.
enum GeoMath {
    static let earthRadius = 6_371_000.0

    /// East/north offset in metres from `origin` to `target`.
    /// Equirectangular approximation: error stays under 0.1% for distances below 10 km.
    static func eastNorth(from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D) -> SIMD2<Double> {
        let lat0 = origin.latitude * .pi / 180
        let dLat = (target.latitude - origin.latitude) * .pi / 180
        let dLon = (target.longitude - origin.longitude) * .pi / 180
        return SIMD2(dLon * cos(lat0) * earthRadius, dLat * earthRadius)
    }

    /// Where to draw an object so it reads correctly through the camera.
    ///
    /// Beyond `maxDistance` the object is pulled closer and shrunk by the same factor, so it keeps the
    /// same apparent size and direction but isn't clipped by the renderer or lost in tracking drift.
    static func displayPlacement(offset: SIMD2<Double>, maxDistance: Double = 120) -> (position: SIMD3<Float>, scale: Float) {
        let distance = simd_length(offset)
        let k = distance > maxDistance ? maxDistance / distance : 1
        return (SIMD3(Float(offset.x * k), 0, Float(-offset.y * k)), Float(k))
    }

    /// Compass bearing in degrees (0 = north, 90 = east) from `origin` to `target`.
    static func bearing(from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D) -> Double {
        let offset = eastNorth(from: origin, to: target)
        let degrees = atan2(offset.x, offset.y) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
