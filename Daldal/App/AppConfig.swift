import Foundation

/// Network endpoints. Development uses free public services; production must point at our own servers.
enum MapConfig {
    /// OpenMapTiles-schema vector tiles (OpenStreetMap data). OpenFreeMap is free and keyless,
    /// which is fine for development. Before launch, host our own Protomaps/OpenMapTiles build.
    static let vectorTilesURL = URL(string: "https://tiles.openfreemap.org/planet")!
    static let glyphsURLTemplate = "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf"
}

enum SearchConfig {
    /// Photon geocoder (OpenStreetMap). The public instance is fair-use only: self-host before launch.
    static let photonBaseURL = URL(string: "https://photon.komoot.io")!
    /// Public OSM services ask every client to identify itself. Add a contact URL once there is one.
    static let userAgent = "Daldal/0.1 (iOS)"
}
