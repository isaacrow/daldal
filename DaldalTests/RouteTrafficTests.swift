import CoreLocation
import Foundation
import Testing
@testable import Daldal

@MainActor
struct RouteTrafficTests {
    /// A straight 1 km road heading east, from Baghdad.
    let start = CLLocationCoordinate2D(latitude: 33.3000, longitude: 44.4000)
    var metreOfLongitude: Double { 1 / (111_320 * cos(33.3 * .pi / 180)) }
    var road: [CLLocationCoordinate2D] {
        [start, CLLocationCoordinate2D(latitude: 33.3, longitude: 44.4 + 1000 * metreOfLongitude)]
    }

    private func traffic(_ lines: [(from: Double, to: Double, level: Int)], offset: Double = 0) -> Data {
        let features = lines.map { line -> [String: Any] in
            let lat = 33.3 + offset / 111_320
            return ["type": "Feature", "properties": ["level": line.level],
                    "geometry": ["type": "LineString",
                                 "coordinates": [[44.4 + line.from * metreOfLongitude, lat], [44.4 + line.to * metreOfLongitude, lat]]]]
        }
        return try! JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
    }

    @Test func colorsOnlyTheCongestedStretches() throws {
        let data = traffic([(200, 400, 2), (600, 700, 3)])
        let stretches = RouteTraffic.stretches(along: road, traffic: data)
        #expect(stretches.map(\.level) == [2, 3])
        let heavy = try #require(stretches.first)
        let startsAt = (heavy.coordinates.first!.longitude - 44.4) / metreOfLongitude
        let endsAt = (heavy.coordinates.last!.longitude - 44.4) / metreOfLongitude
        #expect(abs(startsAt - 200) < 45)
        #expect(abs(endsAt - 400) < 45)
    }

    @Test func ignoresTrafficOnAParallelStreet() {
        // 60 m away: a different road, not ours.
        #expect(RouteTraffic.stretches(along: road, traffic: traffic([(0, 1000, 3)], offset: 60)).isEmpty)
    }

    @Test func noDataMeansNoColours() {
        #expect(RouteTraffic.stretches(along: road, traffic: nil).isEmpty)
    }
}

@MainActor
struct HistoryTests {
    let history = HistoryStore()

    @Test func bundledEventsLoadAndStopBefore1950() {
        #expect(history.events.count > 50)
        #expect(history.events.allSatisfy { $0.year < 1950 })
    }

    @Test func karbalaHasItsBattle() {
        let shrine = CLLocationCoordinate2D(latitude: 32.6164, longitude: 44.0324)
        let events = history.events(near: shrine, languageCode: "ar")
        #expect(events.contains { $0.year == 680 })
        #expect(events.map(\.year) == events.map(\.year).sorted())
    }

    @Test func yearsBeforeChristAreLabelled() throws {
        let babylon = history.events(near: CLLocationCoordinate2D(latitude: 32.5422, longitude: 44.4211), languageCode: "en")
        let ancient = try #require(babylon.first { $0.year < 0 })
        #expect(ancient.yearText.contains(String(-ancient.year)))
        #expect(ancient.yearText != String(ancient.year))
    }
}
