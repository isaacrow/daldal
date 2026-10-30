import CoreLocation
import Foundation
import Testing
@testable import Daldal

private final class BundleToken {}

@MainActor
struct RouteMathTests {
    let start = CLLocationCoordinate2D(latitude: 33.3000, longitude: 44.4000)
    /// A straight 1 km road heading east.
    var road: [CLLocationCoordinate2D] {
        let end = CLLocationCoordinate2D(latitude: 33.3000, longitude: 44.4000 + 1000 / (111_320 * cos(33.3 * .pi / 180)))
        return [start, end]
    }

    @Test func distanceAlongProjectsOntoTheRoad() throws {
        let beside = CLLocationCoordinate2D(latitude: 33.3000 + 20 / 111_320.0, longitude: road[0].longitude + (road[1].longitude - road[0].longitude) * 0.4)
        let along = try #require(RouteMath.distanceAlong(road, to: beside, maxOffset: 35))
        #expect(abs(along - 400) < 1)
        #expect(RouteMath.distanceAlong(road, to: beside, maxOffset: 10) == nil, "20 m off the road is too far at 10 m")
    }

    @Test func overlapTellsSameRoadFromDifferentRoad() {
        let parallelFar = road.map { CLLocationCoordinate2D(latitude: $0.latitude + 500 / 111_320.0, longitude: $0.longitude) }
        let dense = (0...20).map { i in
            CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude + (road[1].longitude - start.longitude) * Double(i) / 20)
        }
        #expect(RouteMath.overlap(dense, with: road) == 1)
        #expect(RouteMath.overlap(parallelFar, with: road) == 0)
    }

    /// Re-encoding a real Valhalla geometry must give back exactly the string Valhalla sent.
    @Test func polylineRoundTripsRealValhallaGeometry() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "valhalla-baghdad-osrm", withExtension: "json"))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let original = try #require(((json?["routes"] as? [[String: Any]])?.first?["geometry"]) as? String)
        let route = try #require(DaldalRouteProvider.parse(osrmResponse: Data(contentsOf: url)).first)
        #expect(RouteMath.encodePolyline6(route.geometry.map(\.coordinate2D)) == original)
    }
}

/// Serialized: these tests change the shared "traffic.share" setting.
@MainActor
@Suite(.serialized)
struct ProbePrivacyTests {
    /// Drives east at 15 m/s, one fix every 5 s, for `seconds`.
    func drive(_ recorder: ProbeRecorder, seconds: Int) -> [CLLocation] {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let metresPerDegree = 111_320 * cos(33.3 * .pi / 180)
        var fixes: [CLLocation] = []
        for s in stride(from: 0, through: seconds, by: 5) {
            let fix = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 33.3, longitude: 44.4 + Double(s) * 15 / metresPerDegree),
                altitude: 0, horizontalAccuracy: 8, verticalAccuracy: 8, course: 90, speed: 15,
                timestamp: t0.addingTimeInterval(Double(s))
            )
            recorder.record(fix)
            fixes.append(fix)
        }
        return fixes
    }

    @Test func neverSendsTheFirstOrLastThreeHundredMetres() {
        UserDefaults.standard.set(true, forKey: "traffic.share")
        // A server that never answers keeps everything in `pending`, so we can inspect it.
        let recorder = ProbeRecorder(upload: { _, _ in throw URLError(.notConnectedToInternet) })
        recorder.begin()
        let fixes = drive(recorder, seconds: 200) // 3 km
        let start = fixes[0], end = fixes[fixes.count - 1]

        let sent = recorder.pending.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
        #expect(!sent.isEmpty)
        for point in sent {
            #expect(point.distance(from: start) >= ProbeRecorder.privacyMargin)
            #expect(point.distance(from: end) > ProbeRecorder.privacyMargin)
        }
    }

    @Test func recordsNothingWhenSharingIsOff() {
        UserDefaults.standard.set(false, forKey: "traffic.share")
        defer { UserDefaults.standard.set(true, forKey: "traffic.share") }
        let recorder = ProbeRecorder(upload: { _, _ in })
        recorder.begin()
        _ = drive(recorder, seconds: 200)
        #expect(recorder.pending.isEmpty)
    }

    @Test func recordsNothingWithoutAServer() {
        let recorder = ProbeRecorder(upload: nil)
        recorder.begin()
        _ = drive(recorder, seconds: 200)
        #expect(recorder.pending.isEmpty)
    }
}

struct LivePhrasesTests {
    let ar = ManeuverPhraser(languageCode: "ar")
    let en = ManeuverPhraser(languageCode: "en")

    @Test func reportWarnings() {
        #expect(ar.reportAhead(.accident, distance: 480) == "انتبه، حادث بعد 500 متر")
        #expect(en.reportAhead(.police, distance: 1_200) == "Police reported in 1 kilometer")
    }

    @Test(arguments: [(1, "دقيقة واحدة"), (2, "دقيقتين"), (7, "7 دقائق"), (10, "10 دقائق"), (15, "15 دقيقة")])
    func arabicMinuteAgreement(n: Int, expected: String) {
        #expect(ar.arabicMinutes(n) == expected)
    }

    @Test func fasterRouteOffer() {
        #expect(ar.fasterRoute(saving: 420) == "وجدت طريقاً أسرع يوفّر 7 دقائق")
        #expect(en.fasterRoute(saving: 50) == "Found a faster route that saves 1 minute")
    }
}
