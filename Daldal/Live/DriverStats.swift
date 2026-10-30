import CoreLocation
import Foundation
import Observation

/// Your own driving record: kept only on this phone, never uploaded.
@Observable
final class DriverStats {
    private(set) var metresDriven: Double = 0
    private(set) var trips = 0
    private(set) var secondsDriving: Double = 0
    private(set) var reportsSent = 0
    private(set) var confirmations = 0
    private(set) var placesExplored: Set<String> = []

    @ObservationIgnored private var lastPoint: CLLocation?
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "driver.stats.v1"

    private struct Snapshot: Codable {
        var metres: Double, trips: Int, seconds: Double, reports: Int, confirmations: Int, places: [String]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            metresDriven = s.metres
            trips = s.trips
            secondsDriving = s.seconds
            reportsSent = s.reports
            confirmations = s.confirmations
            placesExplored = Set(s.places)
        }
    }

    // MARK: Recording

    func tripStarted() {
        trips += 1
        lastPoint = nil
        save()
    }

    /// Adds the distance and time since the previous fix of this trip. Ignores GPS jumps.
    func drove(to location: CLLocation) {
        defer { lastPoint = location }
        guard let last = lastPoint, location.horizontalAccuracy >= 0, location.horizontalAccuracy < 50 else { return }
        let dt = location.timestamp.timeIntervalSince(last.timestamp)
        let d = location.distance(from: last)
        guard dt > 0, dt < 30, d / dt < 70 else { return } // Faster than 250 km/h is a GPS jump, not driving.
        metresDriven += d
        secondsDriving += dt
        if Int(metresDriven) % 500 < Int(d) { save() } // Save every half kilometre, not every fix.
    }

    func tripEnded() {
        lastPoint = nil
        save()
    }

    func reportSent() { reportsSent += 1; save() }
    func confirmed() { confirmations += 1; save() }
    func explored(_ placeID: String) {
        if placesExplored.insert(placeID).inserted { save() }
    }

    // MARK: Level

    /// Points: driving earns a little, helping other drivers earns more.
    var points: Int { Int(metresDriven / 1000) + reportsSent * 10 + confirmations * 3 + placesExplored.count * 5 }

    static let levels: [(points: Int, name: LocalizedStringResource)] = [
        (0, "Newcomer"), (100, "Driver"), (400, "Road regular"), (1_200, "Road guide"), (3_000, "Road master"),
    ]

    var level: Int { Self.levels.lastIndex { points >= $0.points } ?? 0 }

    /// Progress from this level to the next, 0...1 (1 at the top level).
    var progressToNext: Double {
        guard level + 1 < Self.levels.count else { return 1 }
        let from = Self.levels[level].points, to = Self.levels[level + 1].points
        return Double(points - from) / Double(to - from)
    }

    private func save() {
        let snapshot = Snapshot(metres: metresDriven, trips: trips, seconds: secondsDriving, reports: reportsSent,
                                confirmations: confirmations, places: Array(placesExplored))
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: Self.key) }
    }
}
