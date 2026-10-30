import Network
import Observation

/// Whether the phone can reach the internet right now. The map switches between online tiles and
/// downloaded cities on this, so a downloaded city never shows blank tiles in a dead zone.
@Observable
final class Connectivity {
    private(set) var isOnline = true

    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                if self?.isOnline != online { self?.isOnline = online }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.daldal.connectivity"))
    }

    deinit { monitor.cancel() }
}
