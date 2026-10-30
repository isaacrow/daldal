import CoreLocation
import Foundation
import Observation

/// Live traffic, driver reports and closures for the area around the user.
@Observable
final class LiveStore {
    private(set) var reports: [LiveReport] = []
    /// GeoJSON of congested road segments, straight from the server.
    private(set) var traffic: Data?
    /// Reports this phone already voted on or sent, so we never ask "still there?" about them.
    private(set) var handled: Set<String> = []
    private(set) var lastSent: ReportType?

    var isAvailable: Bool { LiveAPI.shared != nil }

    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var lastBox: GeoBox?
    @ObservationIgnored private var closures: (polygons: [[[Double]]], fetched: Date) = ([], .distantPast)

    /// Fetches reports and traffic around `center`. Throttled: at most every 45 s unless the area changed.
    func refresh(around center: CLLocationCoordinate2D, radius: CLLocationDistance = 6000, force: Bool = false) async {
        guard let api = LiveAPI.shared else { return }
        let box = GeoBox.around(center, radius: radius)
        let moved = lastBox.map { abs($0.minLat - box.minLat) > 0.02 || abs($0.minLon - box.minLon) > 0.02 } ?? true
        guard force || moved || Date.now.timeIntervalSince(lastRefresh) > 45 else { return }
        lastRefresh = .now
        lastBox = box
        async let fetchedReports = try? api.reports(in: box)
        async let fetchedTraffic = try? api.traffic(in: box)
        if let fetched = await fetchedReports { reports = fetched }
        if let fetched = await fetchedTraffic { traffic = fetched }
    }

    func send(_ type: ReportType, at location: CLLocation) async -> Bool {
        guard let api = LiveAPI.shared else { return false }
        do {
            let id = try await api.report(type, at: location)
            handled.insert(id)
            lastSent = type
            await refresh(around: location.coordinate, force: true)
            return true
        } catch {
            return false
        }
    }

    func vote(_ report: LiveReport, stillThere: Bool) {
        handled.insert(report.id)
        if !stillThere { reports.removeAll { $0.id == report.id } } // Hide it here right away.
        guard let api = LiveAPI.shared else { return }
        Task { try? await api.vote(reportID: report.id, stillThere: stillThere) }
    }

    /// Confirmed road closures for routing, refreshed at most every two minutes.
    func currentClosures() async -> [[[Double]]] {
        guard let api = LiveAPI.shared else { return [] }
        if Date.now.timeIntervalSince(closures.fetched) > 120, let fresh = try? await api.closures() {
            closures = (fresh, .now)
        }
        return closures.polygons
    }
}
