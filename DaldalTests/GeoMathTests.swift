import CoreLocation
import simd
import Testing
@testable import Daldal

@MainActor
struct GeoMathTests {
    let babylon = CLLocationCoordinate2D(latitude: 32.5422, longitude: 44.4209)

    @Test func pointNorthIsNegativeZ() {
        // 0.001 degrees of latitude is about 111 m.
        let north = CLLocationCoordinate2D(latitude: babylon.latitude + 0.001, longitude: babylon.longitude)
        let offset = GeoMath.eastNorth(from: babylon, to: north)
        #expect(abs(offset.x) < 0.01)
        #expect(abs(offset.y - 111.19) < 0.5)

        let placement = GeoMath.displayPlacement(offset: offset)
        #expect(placement.position.z < 0) // ARKit: -z is north
        #expect(placement.scale == 1)
    }

    @Test func eastShrinksWithLatitude() {
        let east = CLLocationCoordinate2D(latitude: babylon.latitude, longitude: babylon.longitude + 0.001)
        let offset = GeoMath.eastNorth(from: babylon, to: east)
        // 111.19 m * cos(32.54 degrees)
        #expect(abs(offset.x - 93.73) < 0.5)
        #expect(GeoMath.displayPlacement(offset: offset).position.x > 0)
    }

    @Test func matchesCoreLocationDistance() {
        let target = CLLocationCoordinate2D(latitude: 32.5361, longitude: 44.4268) // ~900 m away
        let offset = GeoMath.eastNorth(from: babylon, to: target)
        let expected = CLLocation(latitude: babylon.latitude, longitude: babylon.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        #expect(abs(simd_length(offset) - expected) / expected < 0.005)
    }

    @Test func farObjectsArePulledInAndShrunk() {
        let placement = GeoMath.displayPlacement(offset: SIMD2(0, 1200), maxDistance: 120)
        #expect(abs(placement.position.z + 120) < 0.001)
        #expect(abs(placement.scale - 0.1) < 0.0001)
    }

    @Test(arguments: [(0.001, 0.0, 0.0), (0.0, 0.001, 90.0), (-0.001, 0.0, 180.0), (0.0, -0.001, 270.0)])
    func bearings(dLat: Double, dLon: Double, expected: Double) {
        let target = CLLocationCoordinate2D(latitude: babylon.latitude + dLat, longitude: babylon.longitude + dLon)
        #expect(abs(GeoMath.bearing(from: babylon, to: target) - expected) < 0.01)
    }
}
