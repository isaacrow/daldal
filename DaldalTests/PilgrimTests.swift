import CoreLocation
import Testing
@testable import Daldal

@MainActor
struct PilgrimTests {
    @Test func theBundledRouteRunsFromNajafToKarbala() throws {
        let path = PilgrimRoute.path
        #expect(path.count > 100)
        #expect(abs(PilgrimRoute.length - 79_600) < 2_000)
        let end = try #require(path.last)
        #expect(CLLocation(latitude: end.latitude, longitude: end.longitude)
            .distance(from: CLLocation(latitude: 32.6164, longitude: 44.0324)) < 300)
    }

    @Test func halfwayIsAroundTheMiddlePole() throws {
        let path = PilgrimRoute.path
        let middle = path[path.count / 2]
        let progress = try #require(PilgrimRoute.progress(at: middle))
        #expect(progress.pole > 300 && progress.pole < 1200)
        #expect(progress.left > 20_000 && progress.left < 60_000)
    }

    @Test func baghdadIsNotOnTheWalk() {
        #expect(PilgrimRoute.progress(at: CLLocationCoordinate2D(latitude: 33.3152, longitude: 44.3661)) == nil)
    }

    @Test func arbaeenAndAshuraAreAhead() {
        let days = PilgrimRoute.nextDays(after: .now)
        #expect(days.count == 2)
        #expect(days.allSatisfy { $0.1 > .now.addingTimeInterval(-2 * 86_400) })
    }
}
