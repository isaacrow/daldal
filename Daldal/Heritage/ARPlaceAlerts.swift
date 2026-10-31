import CoreLocation
import Foundation
import Observation
import UserNotifications

/// Tells visitors when they reach a place that has something to explore in AR there (a monument's 3D model,
/// the Battle of Karbala), with a notification that opens it. The AR content itself unlocks only on site.
///
/// iOS lets an app watch 20 places at a time, so the 20 nearest are watched (CLLocationManager region
/// monitoring) and swapped as the visitor travels. CLMonitor is not used: on iOS 26.6 its initialiser raised an
/// exception that ended the app at launch once "Always" location was granted. With "Always" location the alert also arrives when the app is closed; with "While Using"
/// it arrives while the app is open or navigating.
@Observable
final class ARPlaceAlerts: NSObject, UNUserNotificationCenterDelegate, CLLocationManagerDelegate {
    struct Spot: Sendable, Equatable {
        let id: String // a Wikidata QID, or "battle:karbala"
        let name: String
        let coordinate: CLLocationCoordinate2D

        static func == (a: Spot, b: Spot) -> Bool { a.id == b.id }
    }

    /// Visitors are "there" within this distance (GPS between buildings is rarely better than 30-50 m).
    static let arrivalRadius: CLLocationDistance = 200
    static let karbalaID = "battle:karbala"

    /// The spot whose notification was tapped, for the map screen to open.
    var opened: String?

    @ObservationIgnored private var spots: [Spot] = []
    @ObservationIgnored private var watchedAround: CLLocation?
    @ObservationIgnored private var askedPermission = false
    @ObservationIgnored private let locationManager = CLLocationManager()

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        locationManager.delegate = self
    }

    func setSpots(_ spots: [Spot]) {
        self.spots = spots
        watchedAround = nil
    }

    /// Called on every location update: alerts on arrival, and keeps the 20 nearest spots watched.
    func update(location: CLLocation) {
        guard !spots.isEmpty else { return }
        // UI tests drive the map; a permission prompt mid-test would cover it.
        if !askedPermission, !ProcessInfo.processInfo.arguments.contains("-uitest-heritage") {
            askedPermission = true
            Task {
                // Not in the first seconds of launch: let the map and location settle first.
                try? await Task.sleep(for: .seconds(8))
                await askPermission()
            }
        }
        if let spot = spots.first(where: { location.distance(from: CLLocation($0.coordinate)) < Self.arrivalRadius }) {
            notify(spot)
        }
        if watchedAround.map({ $0.distance(from: location) > 5_000 }) ?? true {
            watchedAround = location
            watchNearest(to: location)
        }
    }

    // MARK: Notifications

    private func askPermission() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        // Arrival alerts with the app closed need "Always"; iOS shows the upgrade prompt when it chooses.
        if granted, locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
    }

    private func notify(_ spot: Spot) {
        let key = "arAlert.\(spot.id)"
        let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        guard UserDefaults.standard.double(forKey: key) < today else { return } // Once a day per place.
        UserDefaults.standard.set(today, forKey: key)

        let content = UNMutableNotificationContent()
        if spot.id == Self.karbalaID {
            content.title = String(localized: "You're at Karbala")
            content.body = String(localized: "The Battle of Karbala is ready to explore in AR, here where it happened.")
        } else {
            content.title = String(localized: "You're at \(spot.name)")
            content.body = String(localized: "Its 3D model is unlocked here. Open it to explore in AR.")
        }
        content.sound = .default
        content.userInfo = ["spot": spot.id]
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["spot"] as? String else { return }
        await MainActor.run { opened = id }
    }

    // MARK: Watching

    private func watchNearest(to location: CLLocation) {
        // Watching only helps when iOS may wake the app ("Always"); otherwise the in-app check covers it.
        guard locationManager.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let nearest = spots.sorted { location.distance(from: CLLocation($0.coordinate)) < location.distance(from: CLLocation($1.coordinate)) }
            .prefix(20)
        let wanted = Set(nearest.map(\.id))
        for region in locationManager.monitoredRegions where !wanted.contains(region.identifier) {
            locationManager.stopMonitoring(for: region)
        }
        let watched = Set(locationManager.monitoredRegions.map(\.identifier))
        for spot in nearest where !watched.contains(spot.id) {
            let region = CLCircularRegion(center: spot.coordinate, radius: Self.arrivalRadius, identifier: spot.id)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            locationManager.startMonitoring(for: region)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in
            if let spot = self.spots.first(where: { $0.id == id }) { self.notify(spot) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?,
                                     withError error: any Error) {
        // A region that can't be watched just goes without; the in-app check on location updates still works.
    }
}

private extension CLLocation {
    convenience init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
