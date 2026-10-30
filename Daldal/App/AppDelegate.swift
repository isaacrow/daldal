import UIKit

/// Owns the services that must outlive any one screen, and receives background download events.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let cities = CityMapsStore()
    let connectivity = Connectivity()
    let voice = VoiceGuide(languageCode: AppLanguage.code)
    let live = LiveStore()
    let stats = DriverStats()
    lazy var navigation = NavigationModel(cities: cities, voice: voice, live: live, stats: stats)

    /// iOS relaunches the app when a background city download finishes; hand the session back to it.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == CityMapsConfig.backgroundSessionID else { return completionHandler() }
        cities.backgroundCompletionHandler = completionHandler
        cities.reconnectBackgroundSession()
    }
}
