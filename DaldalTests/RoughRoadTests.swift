import CoreLocation
import Testing
@testable import Daldal

@MainActor
struct RoughRoadTests {
    private func spot(_ lat: Double, _ lon: Double) -> CLLocation { CLLocation(latitude: lat, longitude: lon) }

    @Test func joltsAtTheSameSpotMerge() {
        let store = RoughRoadStore()
        store.clear()
        store.record(at: spot(33.3000, 44.4000), strength: 0.6)
        let again = store.record(at: spot(33.30005, 44.40005), strength: 0.9) // ~7 m away
        #expect(store.spots.count == 1)
        #expect(again.hits == 2)
        #expect(again.strength == 0.9)
        store.clear()
    }

    @Test func separateSpotsStaySeparate() {
        let store = RoughRoadStore()
        store.clear()
        store.record(at: spot(33.3000, 44.4000), strength: 0.6)
        store.record(at: spot(33.3010, 44.4000), strength: 0.6) // ~110 m away
        #expect(store.spots.count == 2)
        store.clear()
    }

    @Test func spotsAreSavedOnThePhone() {
        let store = RoughRoadStore()
        store.clear()
        store.record(at: spot(33.3100, 44.4100), strength: 0.7)
        #expect(RoughRoadStore().spots.count == 1)
        store.clear()
    }
}
