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
                        return ordered.compactMap { try? OfflineSearchCache.service(for: $0) }
                    }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Keep location on in the background only while driving; navigation has its own provider.
                    if phase == .active { location.start() } else if phase == .background { location.stop() }
                }
                .onChange(of: location.location) { _, newValue in
                    if let newValue { heritage.update(location: newValue) }
                }
        }
    }
}

/// Opens each city's search index once per version instead of on every keystroke.
enum OfflineSearchCache {
    private static var cached: [String: OfflineSearchService] = [:]

    static func service(for city: InstalledCity) throws -> OfflineSearchService {
        let key = "\(city.id)/\(city.version)"
        if let service = cached[key] { return service }
        let service = try OfflineSearchService(index: city.searchIndex, languageCode: AppLanguage.code)
        cached = cached.filter { !$0.key.hasPrefix("\(city.id)/") } // Drop the city's older build.
        cached[key] = service
        return service
    }
}
