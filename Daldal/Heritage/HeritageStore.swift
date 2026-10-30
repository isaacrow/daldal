import CoreLocation
import Observation

/// The heritage catalogue plus "you are at a site" detection.
@Observable
final class HeritageStore {
    let sites: [HeritageSite]
    /// The closest site within `arrivalRadius`, if any.
    private(set) var nearby: HeritageSite?
    /// Sites the user closed the arrival banner for, so it doesn't keep coming back.
    @ObservationIgnored private var dismissed: Set<String> = []

    /// Archaeological sites like Babylon or Hatra cover hundreds of metres.
    static let arrivalRadius: CLLocationDistance = 400

    init(sites: [HeritageSite] = HeritageCatalog.load()) {
        self.sites = sites
    }

    func site(id: String) -> HeritageSite? {
        sites.first { $0.id == id }
    }

    func update(location: CLLocation) {
        // Ignore poor fixes; a 1 km error would announce the wrong monument.
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100 else { return }
        let closest = sites
            .filter { !dismissed.contains($0.id) }
            .map { ($0, $0.location.distance(from: location)) }
            .filter { $0.1 <= Self.arrivalRadius }
            .min { $0.1 < $1.1 }?.0
        if closest != nearby { nearby = closest }
    }

    func dismissNearby() {
        if let nearby { dismissed.insert(nearby.id) }
        nearby = nil
    }
}
