import CoreLocation
import Observation

/// Drives the search sheet: debounced queries, results, and errors.
@Observable
final class SearchStore {
    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    private(set) var results: [Place] = []
    private(set) var isSearching = false
    private(set) var failed = false
    /// The category being shown ("Toilets near you"), when results came from a category rather than typing.
    private(set) var category: NearbyCategory?
    /// Places to mark on the map: a category's results, or what the assistant found.
    var pinned: [Place] = []
    /// A location handed over by another app (opened link, pasted from the clipboard), for the map to open.
    var incoming: Place?

    /// A place for a location read from a link or coordinates.
    static func place(for found: LocationLink.Found) -> Place {
        var place = Place.droppedPin(at: found.coordinate)
        place.name = found.name ?? String(localized: "Shared location")
        return place
    }

    /// Opens a location from another app's link or copied text; false when the text has none.
    @discardableResult
    func open(sharedText text: String) async -> Bool {
        guard let found = await LocationLink.resolve(text) else { return false }
        incoming = Self.place(for: found)
        return true
    }

    /// Swapped at launch for the hybrid offline/online service.
    @ObservationIgnored var service: any PlaceSearchService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var currentLocation: () -> CLLocation? = { nil }

    init(service: any PlaceSearchService) {
        self.service = service
    }

    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> Place? {
        try? await service.reverse(coordinate)
    }

    /// The nearest places of a kind (toilets, restaurants, fuel…), also pinned on the map.
    func search(category: NearbyCategory) {
        task?.cancel()
        self.category = category
        isSearching = true
        failed = false
        results = []
        task = Task {
            let here = currentLocation()?.coordinate ?? Region.defaultCenter
            do {
                let places = try await Overpass.nearby(category, around: here, languageCode: AppLanguage.code)
                guard !Task.isCancelled else { return }
                results = places
                pinned = places
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
            isSearching = false
        }
    }

    func reset() {
        task?.cancel()
        category = nil
        query = ""
        results = []
        failed = false
        isSearching = false
    }

    private func scheduleSearch() {
        task?.cancel()
        category = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        task = Task {
            // Wait for the user to pause typing so we don't hit the server on every keystroke.
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            // A pasted link or coordinates (from Uber, WhatsApp, Google Maps...) is a place already.
            if let found = await LocationLink.resolve(text) {
                guard !Task.isCancelled else { return }
                results = [Self.place(for: found)]
                failed = false
                isSearching = false
                return
            }
            do {
                let places = try await service.search(text, near: currentLocation()?.coordinate)
                guard !Task.isCancelled else { return }
                results = places
                failed = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
            isSearching = false
        }
    }
}
