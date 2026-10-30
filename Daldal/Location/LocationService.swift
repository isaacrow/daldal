import CoreLocation
import Observation

/// Publishes the user's location while the app is in the foreground.
@Observable
final class LocationService {
    private(set) var location: CLLocation?
    private(set) var isDenied = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var session: CLServiceSession?

    func start() {
        guard task == nil else { return }
        session = CLServiceSession(authorization: .whenInUse)
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                    guard let self else { return }
                    isDenied = update.authorizationDenied || update.authorizationDeniedGlobally
                    if let location = update.location { self.location = location }
                }
            } catch {
                // The stream only ends on cancellation or a CoreLocation failure; the map keeps its last fix.
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.invalidate()
        session = nil
    }
}
