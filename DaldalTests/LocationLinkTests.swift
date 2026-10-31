import CoreLocation
import Testing
@testable import Daldal

@MainActor
struct LocationLinkTests {
    private func coordinate(_ text: String) -> (Double, Double)? {
        LocationLink.parse(text).map { ($0.coordinate.latitude, $0.coordinate.longitude) }
    }

    @Test func plainCoordinates() {
        #expect(coordinate("33.3152, 44.3661")! == (33.3152, 44.3661))
        #expect(coordinate("33.3152N 44.3661E")! == (33.3152, 44.3661))
        #expect(coordinate("geo:32.6164,44.0324")! == (32.6164, 44.0324))
    }

    @Test func googleMapsLinks() {
        #expect(coordinate("https://www.google.com/maps/place/Karbala/@32.6164,44.0324,17z")! == (32.6164, 44.0324))
        #expect(coordinate("https://www.google.com/maps/place/X/data=!3m1!4b1!4m6!3m5!1s0x0!8m2!3d33.3128!4d44.3615")! == (33.3128, 44.3615))
        #expect(coordinate("https://maps.google.com/?q=33.312800,44.361500")! == (33.3128, 44.3615))
    }

    @Test func wazeAppleAndOSMLinks() {
        #expect(coordinate("https://waze.com/ul?ll=33.3128%2C44.3615&navigate=yes")! == (33.3128, 44.3615))
        #expect(coordinate("https://maps.apple.com/?ll=33.3128,44.3615&q=Pickup")! == (33.3128, 44.3615))
        #expect(coordinate("https://www.openstreetmap.org/?mlat=33.3128&mlon=44.3615#map=17/33.3128/44.3615")! == (33.3128, 44.3615))
    }

    @Test func linkInsideAMessageKeepsItsName() throws {
        let found = try #require(LocationLink.parse("Pickup here: https://maps.apple.com/?q=Al%20Mansour%20Mall&ll=33.3128,44.3615"))
        #expect(found.coordinate.latitude == 33.3128)
        #expect(found.name == "Al Mansour Mall")
    }

    @Test func daldalLinks() {
        #expect(coordinate("daldal://place?lat=32.6164&lon=44.0324&name=Shrine")! == (32.6164, 44.0324))
    }

    @Test func plainTextIsNotALocation() {
        #expect(LocationLink.parse("meet me at the cafe at 5") == nil)
        #expect(LocationLink.parse("") == nil)
    }
}
