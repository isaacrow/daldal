import SwiftUI

@main
struct DaldalApp: App {
    @UIApplicationDelegateAdaptor private var services: AppDelegate
    @State private var location = LocationService()
    @State private var map = MapController()
    @State private var search = SearchStore(service: PhotonSearchService())
    @State private var saved = SavedPlacesStore()
    @State private var heritage = HeritageStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ExploreView()
                .environment(location)
                .environment(map)
                .environment(search)
                .environment(saved)
                .environment(heritage)
                .environment(services.packs)
                .environment(services.navigation)
                .environment(services.live)
                .onAppear {
                    search.currentLocation = { [location] in location.location }
                    search.service = HybridSearchService(online: PhotonSearchService()) { [packs = services.packs] in
                        packs.installed.flatMap { try? OfflineSearchCache.service(for: $0) }
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

/// Opens the search index once per installed pack version instead of on every keystroke.
enum OfflineSearchCache {
    private static var cached: (version: String, service: OfflineSearchService)?

    static func service(for pack: InstalledPack) throws -> OfflineSearchService {
        if let cached, cached.version == pack.version { return cached.service }
        let service = try OfflineSearchService(index: pack.searchIndex, languageCode: AppLanguage.code)
        cached = (pack.version, service)
        return service
    }
}
