import Foundation
import Observation

/// Home, work and recent places, kept on device only.
@Observable
final class SavedPlacesStore {
    enum Slot: String, Codable { case home, work }

    private(set) var home: Place?
    private(set) var work: Place?
    private(set) var recents: [Place] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "saved-places.v1"
    private static let maxRecents = 20

    private struct Snapshot: Codable {
        var home: Place?
        var work: Place?
        var recents: [Place]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            home = snapshot.home
            work = snapshot.work
            recents = snapshot.recents
        }
    }

    func place(for slot: Slot) -> Place? {
        slot == .home ? home : work
    }

    func set(_ place: Place, for slot: Slot) {
        switch slot {
        case .home: home = place
        case .work: work = place
        }
        save()
    }

    func recordVisit(_ place: Place) {
        recents.removeAll { $0.id == place.id }
        recents.insert(place, at: 0)
        recents = Array(recents.prefix(Self.maxRecents))
        save()
    }

    func removeRecent(_ place: Place) {
        recents.removeAll { $0.id == place.id }
        save()
    }

    private func save() {
        let snapshot = Snapshot(home: home, work: work, recents: recents)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        }
    }
}
