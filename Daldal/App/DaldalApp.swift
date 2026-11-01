import SwiftUI

@main
struct DaldalApp: App {
    @UIApplicationDelegateAdaptor private var services: AppDelegate
    @State private var location = LocationService()
    @State private var map = MapController()
    @State private var search = SearchStore(service: PhotonSearchService())
    @State private var saved = SavedPlacesStore()
    @State private var heritage = HeritageStore()
    @State private var guide = CityGuideStore()
    @State private var history = HistoryStore()
    @State private var landmarks = LandmarkModelStore()
    @State private var roadFeatures = RoadFeatureStore()
    @State private var arAlerts = ARPlaceAlerts()
    @State private var roughRoads = RoughRoadStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ExploreView()
                .environment(location)
                .environment(map)
                .environment(search)
                .environment(saved)
                .environment(heritage)
                .environment(guide)
                .environment(history)
                .environment(landmarks)
                .environment(roadFeatures)
                .environment(arAlerts)
                .environment(roughRoads)
                .environment(services.cities)
                .environment(services.connectivity)
                .environment(services.navigation)
                .environment(services.live)
                .environment(services.stats)
                .onAppear {
                    search.currentLocation = { [location] in location.location }
                    search.service = HybridSearchService(online: PhotonSearchService()) { [cities = services.cities, location] in
                        // The city you're in comes first, so its "Al-Mansour" wins over another city's.
                        let all = cities.installedCities
                        let here = location.location.map { coordinate in all.filter { $0.contains(coordinate.coordinate) } } ?? []
                        let ordered = here + all.filter { city in !here.contains(city) }
                        // Then the whole-Iraq index built into the app: instant search everywhere, from the first launch.
                        return ordered.compactMap { try? OfflineSearchCache.service(for: $0) } + [OfflineSearchCache.bundled].compactMap(\.self)
                    }
                }
                .onOpenURL { url in
                    // daldal://place?lat=..&lon=..&name=.. and map links handed to Daldal by other apps.
                    Task { await search.open(sharedText: url.absoluteString) }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Keep location on in the background only while driving; navigation has its own provider.
                    if phase == .active { location.start() } else if phase == .background { location.stop() }
                }
                .onChange(of: location.location) { _, newValue in
                    if let newValue {
                        heritage.update(location: newValue)
                        arAlerts.update(location: newValue)
                    }
                }
        }
    }
}

/// Opens each city's search index once per version instead of on every keystroke.
enum OfflineSearchCache {
    private static var cached: [String: OfflineSearchService] = [:]

    /// The whole-Iraq search index shipped inside the app (CI bundles the newest one from the map release).
    static let bundled: OfflineSearchService? = Bundle.main.url(forResource: "iraq-search", withExtension: "sqlite")
        .flatMap { try? OfflineSearchService(index: $0, languageCode: AppLanguage.code) }

    static func service(for city: InstalledCity) throws -> OfflineSearchService {
        let key = "\(city.id)/\(city.version)"
        if let service = cached[key] { return service }
        let service = try OfflineSearchService(index: city.searchIndex, languageCode: AppLanguage.code)
        cached = cached.filter { !$0.key.hasPrefix("\(city.id)/") } // Drop the city's older build.
        cached[key] = service
        return service
    }
}
