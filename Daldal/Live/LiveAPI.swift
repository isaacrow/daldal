import CoreLocation
import Foundation

enum LiveConfig {
    /// The Daldal Live server (`Backend/`). While this is nil, every live feature quietly stays off.
    static let baseURL: URL? = nil // e.g. URL(string: "https://live.daldal.app")
}

/// A random id for this install, used only to stop one phone voting twice or spamming reports.
/// The server stores a salted hash of it. It is never attached to GPS probes.
enum InstallID {
    static var value: String {
        if let existing = UserDefaults.standard.string(forKey: "install.id") { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "install.id")
        return id
    }
}

enum ReportType: String, Codable, CaseIterable, Identifiable, Sendable {
    case jam, accident, police, hazard, flood, closure
    var id: String { rawValue }

    var icon: DaldalIcon {
        switch self {
        case .jam: .reportJam
        case .accident: .reportAccident
        case .police: .reportPolice
        case .hazard: .reportHazard
        case .flood: .reportFlood
        case .closure: .reportClosure
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .jam: "Traffic jam"
        case .accident: "Accident"
        case .police: "Police"
        case .hazard: "Hazard"
        case .flood: "Flooded road"
        case .closure: "Road closed"
        }
    }

    /// Marker colours, chosen to read on both the day and night map.
    var color: (red: Double, green: Double, blue: Double) {
        switch self {
        case .jam: (0.93, 0.55, 0.13)
        case .accident: (0.86, 0.22, 0.24)
        case .police: (0.20, 0.42, 0.85)
        case .hazard: (0.90, 0.68, 0.10)
        case .flood: (0.13, 0.60, 0.80)
        case .closure: (0.45, 0.45, 0.50)
        }
    }
}

struct LiveReport: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let type: ReportType
    let lat: Double
    let lon: Double
    let heading: Double?
    let confirmations: Int

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

struct ProbeSample: Codable, Sendable {
    let t: Double
    let lat: Double
    let lon: Double
    let speed: Double?
    let accuracy: Double
}

/// HTTP client for the live API. Every call fails fast and quietly: live data is a bonus, never a blocker.
struct LiveAPI: Sendable {
    let baseURL: URL
    var session: URLSession = .shared

    static var shared: LiveAPI? { LiveConfig.baseURL.map { LiveAPI(baseURL: $0) } }

    func sendProbes(trip: UUID, points: [ProbeSample]) async throws {
        struct Body: Encodable { let trip: String; let points: [ProbeSample] }
        // Deliberately no install id here: only the per-trip random token ties these points together.
        _ = try await post("v1/probes", Body(trip: trip.uuidString, points: points), identified: false)
    }

    func traffic(in box: GeoBox) async throws -> Data {
        try await get("v1/traffic", query: [URLQueryItem(name: "bbox", value: box.query)])
    }

    func reports(in box: GeoBox) async throws -> [LiveReport] {
        struct Reply: Decodable { let reports: [LiveReport] }
        return try JSONDecoder().decode(Reply.self, from: get("v1/reports", query: [URLQueryItem(name: "bbox", value: box.query)])).reports
    }

    func report(_ type: ReportType, at location: CLLocation) async throws -> String {
        struct Body: Encodable { let type: ReportType; let lat: Double; let lon: Double; let heading: Double? }
        struct Reply: Decodable { let id: String }
        let body = Body(type: type, lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                        heading: location.course >= 0 ? location.course : nil)
        return try JSONDecoder().decode(Reply.self, from: post("v1/reports", body, identified: true)).id
    }

    func vote(reportID: String, stillThere: Bool) async throws {
        struct Body: Encodable { let still_there: Bool }
        _ = try await post("v1/reports/\(reportID)/votes", Body(still_there: stillThere), identified: true)
    }

    /// Extra seconds of traffic on each route right now (0 where there's no data).
    func liveDelays(_ shapes: [(id: String, polyline6: String)]) async throws -> [String: TimeInterval] {
        struct Shape: Encodable { let id: String; let shape: String }
        struct Body: Encodable { let routes: [Shape] }
        struct Reply: Decodable { struct Route: Decodable { let id: String; let delay_s: Double }; let routes: [Route] }
        let data = try await post("v1/eta", Body(routes: shapes.map { Shape(id: $0.id, shape: $0.polyline6) }), identified: false)
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return Dictionary(reply.routes.map { ($0.id, $0.delay_s) }, uniquingKeysWith: { a, _ in a })
    }

    /// Confirmed closures, as polygons for Valhalla's `exclude_polygons` ([[lon, lat], ...] rings).
    func closures() async throws -> [[[Double]]] {
        struct Reply: Decodable { let polygons: [[[Double]]] }
        return try JSONDecoder().decode(Reply.self, from: get("v1/closures", query: [])).polygons
    }

    // MARK: Transport

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path).appending(queryItems: query))
        request.timeoutInterval = 8
        return try await send(request)
    }

    private func post(_ path: String, _ body: some Encodable, identified: Bool) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if identified { request.setValue(InstallID.value, forHTTPHeaderField: "X-Daldal-Install") }
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// A lon/lat box for API queries.
struct GeoBox: Equatable, Sendable {
    var minLon, minLat, maxLon, maxLat: Double

    var query: String { "\(minLon),\(minLat),\(maxLon),\(maxLat)" }

    /// A box around a point, `radius` metres each way.
    static func around(_ c: CLLocationCoordinate2D, radius: Double) -> GeoBox {
        let dLat = radius / 111_320
        let dLon = radius / (111_320 * max(cos(c.latitude * .pi / 180), 0.01))
        return GeoBox(minLon: c.longitude - dLon, minLat: c.latitude - dLat, maxLon: c.longitude + dLon, maxLat: c.latitude + dLat)
    }
}
