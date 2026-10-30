import CoreLocation
import Foundation

/// Forward and reverse geocoding. Phase 2 adds an offline implementation backed by region packs.
protocol PlaceSearchService {
    func search(_ query: String, near: CLLocationCoordinate2D?) async throws -> [Place]
    func reverse(_ coordinate: CLLocationCoordinate2D) async throws -> Place?
}

/// Geocoding through Photon (https://github.com/komoot/photon), built on OpenStreetMap data.
struct PhotonSearchService: PlaceSearchService {
    var baseURL = SearchConfig.photonBaseURL
    var session = URLSession.shared
    var limit = 15

    func search(_ query: String, near: CLLocationCoordinate2D?) async throws -> [Place] {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            // Only Iraq: a search for "Karbala" must never return a street abroad.
            URLQueryItem(name: "bbox", value: Region.photonBoundingBox),
        ]
        if let near, Region.contains(near) {
            // Bias results toward the user without excluding far-away matches.
            items += [URLQueryItem(name: "lat", value: String(near.latitude)),
                      URLQueryItem(name: "lon", value: String(near.longitude))]
        }
        return try await fetch(path: "api", items: items)
    }

    func reverse(_ coordinate: CLLocationCoordinate2D) async throws -> Place? {
        try await fetch(path: "reverse", items: [
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(coordinate.longitude)),
        ]).first
    }

    private func fetch(path: String, items: [URLQueryItem]) async throws -> [Place] {
        var request = URLRequest(url: baseURL.appending(path: path).appending(queryItems: items))
        request.setValue(SearchConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try PhotonResponse.places(from: data)
    }
}

/// Photon returns GeoJSON. Only the fields we use are decoded.
enum PhotonResponse {
    struct Collection: Decodable { let features: [Feature] }
    struct Feature: Decodable {
        let geometry: Geometry
        let properties: Properties
    }
    struct Geometry: Decodable { let coordinates: [Double] }
    struct Properties: Decodable {
        let osm_type: String?
        let osm_id: Int?
        let osm_key: String?
        let osm_value: String?
        let name: String?
        let street: String?
        let housenumber: String?
        let district: String?
        let city: String?
        let state: String?
        let country: String?
    }

    static func places(from data: Data) throws -> [Place] {
        try JSONDecoder().decode(Collection.self, from: data).features.compactMap(place)
    }

    static func place(from feature: Feature) -> Place? {
        let c = feature.geometry.coordinates
        guard c.count >= 2 else { return nil }
        let p = feature.properties
        let lon = c[0], lat = c[1]

        let street = [p.street, p.housenumber].compactMap { $0 }.joined(separator: " ")
        let title = p.name ?? (street.isEmpty ? nil : street) ?? p.city ?? p.state
        guard let title else { return nil }

        let subtitle = [street.isEmpty || street == title ? nil : street, p.district, p.city, p.country]
            .compactMap { $0 }
            .filter { $0 != title }
            .joined(separator: "، ")

        let id = if let type = p.osm_type, let osmID = p.osm_id { "osm:\(type)\(osmID)" } else { "geo:\(lat),\(lon)" }
        return Place(id: id, name: title, subtitle: subtitle, latitude: lat, longitude: lon,
                     category: PlaceCategory(osmKey: p.osm_key, osmValue: p.osm_value))
    }
}
