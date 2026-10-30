import CoreLocation
import Foundation
import Testing
@testable import Daldal

@MainActor
struct PhotonParsingTests {
    /// Trimmed from a real Photon response for "karbala" limited to Iraq.
    let sample = """
    {"type":"FeatureCollection","features":[
      {"type":"Feature","properties":{"osm_type":"W","osm_id":1040938006,"osm_key":"place","osm_value":"city",
       "name":"كربلاء","state":"كربلاء","country":"العراق","countrycode":"IQ"},
       "geometry":{"type":"Point","coordinates":[44.0157931,32.5984057]}},
      {"type":"Feature","properties":{"osm_type":"N","osm_id":42,"osm_key":"amenity","osm_value":"fuel",
       "street":"شارع الإمام علي","housenumber":"12","city":"كربلاء","country":"العراق"},
       "geometry":{"type":"Point","coordinates":[44.02,32.61]}},
      {"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[44.0]}}
    ]}
    """.data(using: .utf8)!

    @Test func parsesPlacesAndSkipsBrokenFeatures() throws {
        let places = try PhotonResponse.places(from: sample)
        #expect(places.count == 2)

        let city = try #require(places.first)
        #expect(city.id == "osm:W1040938006")
        #expect(city.name == "كربلاء")
        #expect(city.category == .city)
        #expect(city.latitude == 32.5984057)
        #expect(city.longitude == 44.0157931)
        #expect(!city.subtitle.contains("كربلاء، كربلاء"))
    }

    @Test func unnamedPlaceFallsBackToStreetAddress() throws {
        let station = try PhotonResponse.places(from: sample)[1]
        #expect(station.name == "شارع الإمام علي 12")
        #expect(station.category == .fuel)
    }

    @Test func categories() {
        #expect(PlaceCategory(osmKey: "historic", osmValue: "ruins") == .heritage)
        #expect(PlaceCategory(osmKey: "amenity", osmValue: "place_of_worship") == .worship)
        #expect(PlaceCategory(osmKey: "shop", osmValue: "bakery") == .shop)
        #expect(PlaceCategory(osmKey: nil, osmValue: nil) == .other)
    }
}

@MainActor
struct HeritageTests {
    @Test func bundledCatalogueIsInIraq() {
        let sites = HeritageCatalog.load()
        #expect(sites.count >= 30)
        #expect(sites.contains { $0.nameEn == "Babylon" && $0.isWorldHeritage })
        for site in sites {
            #expect(Region.contains(site.coordinate), "\(site.id) is outside Iraq")
            #expect(site.nameAr != nil || site.nameEn != nil)
        }
    }

    @Test func arrivalOnlyWithinRadiusAndWithGoodGPS() throws {
        let store = HeritageStore()
        let babylon = try #require(store.sites.first { $0.nameEn == "Babylon" })

        store.update(location: CLLocation(coordinate: babylon.coordinate, altitude: 0,
                                          horizontalAccuracy: 500, verticalAccuracy: 10, timestamp: .now))
        #expect(store.nearby == nil) // 500 m accuracy is too vague

        store.update(location: CLLocation(coordinate: babylon.coordinate, altitude: 0,
                                          horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: .now))
        #expect(store.nearby?.id == babylon.id)

        store.dismissNearby()
        store.update(location: CLLocation(coordinate: babylon.coordinate, altitude: 0,
                                          horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: .now))
        #expect(store.nearby?.id != babylon.id)
    }
}
