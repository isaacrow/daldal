import UIKit

/// Owns the services that must outlive any one screen, and receives background download events.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let packs = OfflinePackManager()
    let voice = VoiceGuide(languageCode: AppLanguage.code)
    let live = LiveStore()
    lazy var navigation = NavigationModel(packs: packs, voice: voice, live: live)

    /// iOS relaunches the app when a background pack download finishes; hand the session back to it.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == PackConfig.backgroundSessionID else { return completionHandler() }
        packs.backgroundCompletionHandler = completionHandler
        packs.reconnectBackgroundSession()
    }
}
