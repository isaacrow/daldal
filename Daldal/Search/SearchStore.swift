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

    func reset() {
        task?.cancel()
        query = ""
        results = []
        failed = false
        isSearching = false
    }

    private func scheduleSearch() {
        task?.cancel()
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
