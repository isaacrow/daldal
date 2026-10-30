@preconcurrency import FerrostarCore
@preconcurrency import FerrostarCoreFFI
import Foundation
import Valhalla
import ValhallaConfigModels

enum RoutingConfig {
    /// FOSSGIS's public Valhalla server: fair use, development only. Self-host before launch
    /// (same Docker image as `scripts/pack/build-iraq-pack.sh`).
    static let onlineEndpoint = "https://valhalla1.openstreetmap.de/route"
    static let profile = "auto"

    /// Valhalla request options shared by online and offline routing.
    static func options(closures: [[[Double]]] = []) -> [String: Any] {
        var options: [String: Any] = [
            "units": "kilometers",
            // Always English: Valhalla's ar-SA narration is broken (English departures, numbers dropped:
            // "اكمل لغاية كيلومترات"). Daldal writes its own Arabic from maneuver data (ManeuverPhraser).
            "language": "en-US",
            "alternates": 2,
            "costing_options": [
                "auto": [
                    // Iraqi drivers favour main roads; side streets are often unpaved or blocked.
                    "use_highways": 1.0,
                    "use_tracks": 0.0,
                    "use_living_streets": 0.1,
                ],
            ],
        ]
        // Road closures confirmed by two drivers: routes go around them, online and offline alike.
        if !closures.isEmpty { options["exclude_polygons"] = closures }
        return options
    }
}

/// Routes with on-device Valhalla when the Iraq pack is installed, and the online server otherwise.
///
/// Both paths send the exact request Ferrostar's own Valhalla generator builds (OSRM format with
/// banner and voice instructions), and both parse the reply with Ferrostar's OSRM parser,
/// so a route looks the same to the rest of the app wherever it came from.
///
/// An actor, so on-device route calculation never runs on the main thread.
actor DaldalRouteProvider: CustomRouteProvider {
    enum Source: Equatable { case device, server }

    private let pack: @MainActor @Sendable () -> InstalledPack?
    private let closures: @MainActor @Sendable () async -> [[[Double]]]
    private let session: URLSession
    private let parser = createOsrmResponseParser(polylinePrecision: 6)

    private var offlineRouter: Valhalla?
    private var offlineRouterVersion: String?
    private(set) var lastSource: Source?

    init(pack: @escaping @MainActor @Sendable () -> InstalledPack?,
         closures: @escaping @MainActor @Sendable () async -> [[[Double]]] = { [] },
         session: URLSession = .shared) {
        self.closures = closures
        self.pack = pack
        self.session = session
    }

    func getRoutes(userLocation: UserLocation, waypoints: [Waypoint]) async throws -> [Route] {
        let generator = try createValhallaRequestGenerator(
            endpointUrl: RoutingConfig.onlineEndpoint,
            profile: RoutingConfig.profile,
            optionsJson: String(data: JSONSerialization.data(withJSONObject: RoutingConfig.options(closures: await closures())),
                                encoding: .utf8)
        )
        guard case let .httpPost(url, headers, body) = try generator.generateRequest(userLocation: userLocation, waypoints: waypoints)
        else { throw RoutingError.unexpectedRequest }

        if let pack = await pack() {
            do {
                let routes = try routeOnDevice(body: body, pack: pack)
                if !routes.isEmpty {
                    lastSource = .device
                    return routes
                }
            } catch {
                // A damaged or mismatched graph must not strand the driver: fall through to the server.
            }
        }

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RoutingError.server
        }
        lastSource = .server
        return try parser.parseResponse(response: data)
    }

    private func routeOnDevice(body: Data, pack: InstalledPack) throws -> [Route] {
        if offlineRouter == nil || offlineRouterVersion != pack.version {
            offlineRouter?.close()
            offlineRouter = try Valhalla(ValhallaConfig(tileExtractTar: pack.routingTiles))
            offlineRouterVersion = pack.version
        }
        guard let router = offlineRouter, let request = String(data: body, encoding: .utf8) else { return [] }
        let reply = try router.route(rawRequest: request)
        return try parser.parseResponse(response: Data(reply.utf8))
    }
}

extension DaldalRouteProvider {
    /// Parses a Valhalla OSRM-format reply the same way live routing does. Used by tests with real fixtures.
    nonisolated static func parse(osrmResponse data: Data) throws -> [Route] {
        try createOsrmResponseParser(polylinePrecision: 6).parseResponse(response: data)
    }
}

enum RoutingError: LocalizedError {
    case unexpectedRequest, server, noRoute

    var errorDescription: String? {
        switch self {
        case .unexpectedRequest, .server: String(localized: "Couldn't get directions right now. Try again in a moment.")
        case .noRoute: String(localized: "There's no drivable route to this place.")
        }
    }
}
