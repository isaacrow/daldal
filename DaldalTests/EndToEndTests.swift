import CoreLocation
import Foundation
import Testing
@testable import Daldal

/// Runs the real pipelines against the real servers, the way a phone would.
/// These need the internet; GitHub's build machines have it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct EndToEndTests {
    let tahrir = CLLocation(latitude: 33.3128, longitude: 44.3915)
    let kadhimiya = Place(id: "test:kadhimiya", name: "Kadhimiya", subtitle: "", latitude: 33.3800, longitude: 44.3380, category: .worship)

    private func waitFor(_ condition: () -> Bool, seconds: Double = 40) async {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition(), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The app keeps these for its whole life (AppDelegate). Freeing them mid-speech crashes inside
    /// AVSpeechSynthesizer, so tests keep them alive the same way.
    private static var keepAlive: [AnyObject] = []

    @Test func directionsFromTahrirToKadhimiya() async throws {
        let nav = NavigationModel(cities: CityMapsStore(), voice: VoiceGuide(languageCode: "ar"), live: LiveStore())
        Self.keepAlive.append(nav)
        nav.planRoute(to: kadhimiya, from: tahrir)
        #expect(nav.phase == .planning)

        await waitFor { nav.phase == .preview }
        #expect(nav.phase == .preview)
        #expect(nav.errorMessage == nil, "routing error: \(nav.errorMessage ?? "")")
        let route = try #require(nav.selectedRoute, "no route came back")
        #expect(route.distance > 5_000 && route.distance < 20_000, "unexpected distance \(route.distance)")
        #expect(route.steps.count > 3)

        nav.start()
        #expect(nav.phase == .navigating)
        await waitFor { nav.state?.isNavigating == true }
        #expect(nav.state?.isNavigating == true, "Ferrostar didn't start navigating")
        #expect(nav.state?.currentProgress?.distanceRemaining ?? 0 > 1_000)

        nav.stop()
        #expect(nav.phase == .idle)
    }

    @Test func walkingDirections() async throws {
        let provider = DaldalRouteProvider(cities: { [] })
        let routes = try await provider.getRoutes(
            userLocation: .init(clLocation: tahrir),
            waypoints: [.init(coordinate: .init(cl: kadhimiya.coordinate), kind: .break)],
            profile: .pedestrian
        )
        let route = try #require(routes.first)
        // A walk is slower than a drive over the same ground: well over an hour for ~9 km.
        #expect(route.expectedTravelTime > 60 * 60)
    }

    @Test func searchFindsKarbala() async throws {
        let results = try await PhotonSearchService().search("كربلاء", near: tahrir.coordinate)
        #expect(results.contains { $0.name.contains("كربلاء") })
        #expect(results.allSatisfy { Region.contains($0.coordinate) })
    }
}
