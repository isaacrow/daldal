import Foundation
import Testing
@testable import Daldal

private final class BundleToken {}

@MainActor
struct RouteParsingTests {
    /// A real Valhalla reply: Tahrir Square to Kadhimiya, Baghdad (fetched during development).
    func loadRoute() throws -> Data {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "valhalla-baghdad-osrm", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test func parsesRealBaghdadRoute() throws {
        let routes = try DaldalRouteProvider.parse(osrmResponse: loadRoute())
        let route = try #require(routes.first)
        #expect(abs(route.distance - 10_774) < 5)
        #expect(route.steps.count == 9)
        #expect(route.expectedTravelTime > 25 * 60 && route.expectedTravelTime < 40 * 60)
    }

    /// A step's banner describes the maneuver at the *end* of that step, onto the *next* step's road.
    @Test func maneuverComesFromBannerAndNextRoad() throws {
        let steps = try #require(DaldalRouteProvider.parse(osrmResponse: loadRoute()).first?.steps)
        let first = try #require(Maneuver(step: steps[0], next: steps[1]))
        #expect(first.kind == .endOfRoad)
        #expect(first.direction == .right)
        #expect(first.roadName == "شارع 14 تموز")

        let fork = try #require(Maneuver(step: steps[1], next: steps[2]))
        #expect(fork.kind == .fork)
        #expect(fork.direction == .slightLeft)
    }
}

struct ManeuverPhraserTests {
    let ar = ManeuverPhraser(languageCode: "ar")
    let en = ManeuverPhraser(languageCode: "en")

    @Test func arabicTurnWithDistanceAndRoad() {
        let m = Maneuver(kind: .turn, direction: .right, roadName: "شارع الرشيد")
        #expect(ar.spoken(m, distance: 412) == "بعد 400 متر، انعطف يميناً إلى شارع الرشيد")
        #expect(en.spoken(m, distance: 412) == "In 400 meters, turn right onto شارع الرشيد")
    }

    @Test func chainsCloseManeuvers() {
        let first = Maneuver(kind: .turn, direction: .left)
        let then = Maneuver(kind: .fork, direction: .slightRight)
        #expect(ar.spoken(first, distance: nil, then: then) == "انعطف يساراً، ثم التزم المسار الأيمن")
        #expect(en.spoken(first, distance: nil, then: then) == "Turn left, then keep right")
    }

    @Test func roundaboutExits() {
        let m = Maneuver(kind: .roundabout, direction: .right, roundaboutExit: 2)
        #expect(ar.action(m) == "عند الدوّار، اسلك المخرج الثاني")
        #expect(en.action(m) == "At the roundabout, take the 2nd exit")
        #expect(en.action(Maneuver(kind: .roundabout, roundaboutExit: 11)) == "At the roundabout, take the 11th exit")
    }

    @Test func arrivalSide() {
        #expect(ar.action(Maneuver(kind: .arrive, direction: .left)) == "وجهتك على اليسار")
        #expect(en.action(Maneuver(kind: .arrive)) == "Your destination is ahead")
    }

    @Test(arguments: [
        (45.0, "50 متر"), (412.0, "400 متر"), (980.0, "كيلومتر واحد"),
        (1_900.0, "كيلومترين"), (2_300.0, "2.5 كيلومتر"), (12_100.0, "12 كيلومتر"),
    ])
    func arabicDistances(meters: Double, expected: String) {
        #expect(ar.spokenDistance(meters) == expected)
    }
}

struct ArabicSearchTests {
    @Test(arguments: [
        ("بَغْدَاد", "بغداد"),
        ("جامع الإمام الأعظم", "جامع الامام الاعظم"),
        ("مستشفى", "مستشفي"),
        ("مدرسة", "مدرسه"),
        ("Café", "cafe"),
        ("بغـــداد", "بغداد"),
    ])
    func normalizes(input: String, expected: String) {
        #expect(ArabicSearchNormalizer.normalize(input) == expected)
    }

    @Test func ftsQueryRequiresEveryWordAndPrefixesTheLast() {
        #expect(OfflineSearchService.ftsQuery("شارع الرش") == "\"شارع\" \"الرش\"*")
        #expect(OfflineSearchService.ftsQuery("  ") == nil)
        // Quotes can't break out of the FTS syntax.
        #expect(OfflineSearchService.ftsQuery("a\"b") == "\"a\" \"b\"*")
    }
}
