import CoreLocation
import Foundation

/// Shares the car's speed and position anonymously while navigating, so everyone gets live traffic.
///
/// Privacy, in order of importance:
/// - Each trip gets a new random token. Nothing links two trips, or a trip to this phone.
/// - The first 300 m of a trip are never sent (where you start is usually home or work).
/// - The last 300 m are always held back and dropped at the end (where you stop, likewise).
/// - The server keeps only per-road averages from at least two trips; raw points are deleted within minutes.
final class ProbeRecorder {
    static let privacyMargin: CLLocationDistance = 300
    static let sampleInterval: TimeInterval = 5
    static let uploadInterval: TimeInterval = 30
    private static let maxQueued = 240

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "traffic.share") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "traffic.share") }
    }

    typealias Upload = (UUID, [ProbeSample]) async throws -> Void

    /// Sends a batch to the server; nil when there is no live server configured.
    private let upload: Upload?
    private var trip: UUID?
    private var start: CLLocation?
    private var leftStartZone = false
    /// Points not yet safe to send: the most recent `privacyMargin` metres of driving.
    private var holdBack: [CLLocation] = []
    private var ready: [ProbeSample] = []
    private var lastSample: Date?
    private var lastUpload = Date.distantPast
    private var uploading = false

    init(upload: Upload? = LiveAPI.shared.map { api in { try await api.sendProbes(trip: $0, points: $1) } }) {
        self.upload = upload
    }

    /// Samples released for sending but not yet confirmed by the server. Exposed for tests.
    var pending: [ProbeSample] { ready }

    func begin() {
        trip = isEnabled && upload != nil ? UUID() : nil
        start = nil
        leftStartZone = false
        holdBack = []
        ready = []
        lastSample = nil
    }

    func record(_ location: CLLocation) {
        guard trip != nil, location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 50 else { return }
        if let lastSample, location.timestamp.timeIntervalSince(lastSample) < Self.sampleInterval { return }
        lastSample = location.timestamp

        guard let start else {
            self.start = location
            return
        }
        if !leftStartZone {
            guard location.distance(from: start) >= Self.privacyMargin else { return }
            leftStartZone = true
        }

        holdBack.append(location)
        // Release points once they are more than the margin behind the car.
        while holdBack.count > 1, Self.pathLength(holdBack) > Self.privacyMargin {
            let point = holdBack.removeFirst()
            ready.append(ProbeSample(
                t: point.timestamp.timeIntervalSince1970,
                lat: point.coordinate.latitude, lon: point.coordinate.longitude,
                speed: point.speed >= 0 ? point.speed : nil,
                accuracy: point.horizontalAccuracy
            ))
        }
        if ready.count > Self.maxQueued { ready.removeFirst(ready.count - Self.maxQueued) }

        if Date.now.timeIntervalSince(lastUpload) >= Self.uploadInterval { flush() }
    }

    /// Ends the trip. Sends what is already safe to send and drops the held-back tail.
    func end() {
        flush()
        trip = nil
        holdBack = []
    }

    private func flush() {
        guard let trip, let upload, !ready.isEmpty, !uploading else { return }
        let batch = Array(ready.prefix(120))
        uploading = true
        lastUpload = .now
        Task {
            defer { uploading = false }
            do {
                try await upload(trip, batch)
                // By timestamp, not count: the queue may have been trimmed while this was in flight.
                if let lastSent = batch.last?.t { ready.removeAll { $0.t <= lastSent } }
            } catch {
                // Keep them for the next attempt; the queue is capped, so a dead zone can't grow it forever.
            }
        }
    }

    private static func pathLength(_ points: [CLLocation]) -> CLLocationDistance {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(from: $1.1) }
    }
}
