import CoreLocation

/// Daldal covers Iraq only. Everything region-specific (search bounds, the default camera,
/// the offline pack, the heritage catalogue) reads from here.
enum Region {
    /// Iraq's bounding box with a small margin, in degrees.
    static let minLongitude = 38.70
    static let minLatitude = 28.95
    static let maxLongitude = 48.80
    static let maxLatitude = 37.45

    /// Central Baghdad (Tahrir Square), used when the user's location isn't known yet.
    static let defaultCenter = CLLocationCoordinate2D(latitude: 33.3128, longitude: 44.3915)

    /// Photon `bbox` parameter: minLon,minLat,maxLon,maxLat.
    static var photonBoundingBox: String {
        "\(minLongitude),\(minLatitude),\(maxLongitude),\(maxLatitude)"
    }

    static func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (minLatitude...maxLatitude).contains(coordinate.latitude)
            && (minLongitude...maxLongitude).contains(coordinate.longitude)
    }
}
