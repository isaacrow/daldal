import CoreLocation

/// Geometry on route polylines. Short distances in Iraq, so a local flat projection is accurate to centimetres.
enum RouteMath {
    /// How far along `path` (metres from its start) the closest point to `point` is,
    /// or nil if `point` is more than `maxOffset` metres from the path.
    static func distanceAlong(_ path: [CLLocationCoordinate2D], to point: CLLocationCoordinate2D, maxOffset: Double) -> Double? {
        guard path.count >= 2 else { return nil }
        let origin = path[0]
        let p = local(point, origin: origin)
        var walked = 0.0
        var best: (offset: Double, along: Double)?
        for (a, b) in zip(path, path.dropFirst()) {
            let pa = local(a, origin: origin), pb = local(b, origin: origin)
            let segment = pb - pa
            let length = segment.length
            let t = length > 0 ? max(0, min(1, (p - pa).dot(segment) / (length * length))) : 0
            let offset = (p - (pa + segment * t)).length
            if offset <= maxOffset, best == nil || offset < best!.offset {
                best = (offset, walked + length * t)
            }
            walked += length
        }
        return best?.along
    }

    /// The point `distance` metres along `path` from its start (clamped to the path's ends).
    static func coordinate(along path: [CLLocationCoordinate2D], at distance: Double) -> CLLocationCoordinate2D? {
        guard let first = path.first else { return nil }
        guard distance > 0 else { return first }
        var walked = 0.0
        for (a, b) in zip(path, path.dropFirst()) {
            let pa = local(a, origin: first), pb = local(b, origin: first)
            let length = (pb - pa).length
            if walked + length >= distance, length > 0 {
                let t = (distance - walked) / length
                return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                              longitude: a.longitude + (b.longitude - a.longitude) * t)
            }
            walked += length
        }
        return path.last
    }

    /// Length of `path` in metres.
    static func length(_ path: [CLLocationCoordinate2D]) -> Double {
        guard let first = path.first else { return 0 }
        return zip(path, path.dropFirst()).reduce(0) { $0 + (local($1.1, origin: first) - local($1.0, origin: first)).length }
    }

    /// Share of `candidate`'s points that lie within `tolerance` metres of `reference`.
    /// Two routes that share almost every point are the same road, so "faster" would be noise.
    static func overlap(_ candidate: [CLLocationCoordinate2D], with reference: [CLLocationCoordinate2D], tolerance: Double = 30) -> Double {
        let sampled = stride(from: 0, to: candidate.count, by: max(1, candidate.count / 60)).map { candidate[$0] }
        guard !sampled.isEmpty else { return 0 }
        let near = sampled.filter { distanceAlong(reference, to: $0, maxOffset: tolerance) != nil }
        return Double(near.count) / Double(sampled.count)
    }

    /// Google/OSRM polyline encoding at precision 6, as Valhalla expects.
    static func encodePolyline6(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var output = ""
        var previous = (lat: 0, lon: 0)
        for c in coordinates {
            let current = (lat: Int((c.latitude * 1e6).rounded()), lon: Int((c.longitude * 1e6).rounded()))
            for delta in [current.lat - previous.lat, current.lon - previous.lon] {
                var value = delta < 0 ? ~(delta << 1) : delta << 1
                while value >= 0x20 {
                    output.append(Character(UnicodeScalar(UInt8((0x20 | (value & 0x1F)) + 63))))
                    value >>= 5
                }
                output.append(Character(UnicodeScalar(UInt8(value + 63))))
            }
            previous = current
        }
        return output
    }

    // MARK: Local plane

    private static func local(_ c: CLLocationCoordinate2D, origin: CLLocationCoordinate2D) -> PlaneVector {
        let metresPerDegree = 111_320.0
        return PlaneVector(x: (c.longitude - origin.longitude) * metresPerDegree * cos(origin.latitude * .pi / 180),
                           y: (c.latitude - origin.latitude) * metresPerDegree)
    }
}

/// A 2D vector in metres on a local flat plane.
fileprivate struct PlaneVector {
    var x, y: Double

    var length: Double { (x * x + y * y).squareRoot() }
    func dot(_ other: PlaneVector) -> Double { x * other.x + y * other.y }

    static func - (a: PlaneVector, b: PlaneVector) -> PlaneVector { PlaneVector(x: a.x - b.x, y: a.y - b.y) }
    static func + (a: PlaneVector, b: PlaneVector) -> PlaneVector { PlaneVector(x: a.x + b.x, y: a.y + b.y) }
    static func * (a: PlaneVector, t: Double) -> PlaneVector { PlaneVector(x: a.x * t, y: a.y * t) }
}
