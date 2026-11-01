import CoreLocation
import Foundation
import Testing
@testable import Daldal

@MainActor
struct PrayerTimesTests {
    let baghdad = CLLocationCoordinate2D(latitude: 33.3152, longitude: 44.3661)
    let iraq = TimeZone(identifier: "Asia/Baghdad")!

    private func clock(_ date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = iraq
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return Double(c.hour!) + Double(c.minute!) / 60
    }

    private var november1: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = iraq
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9))!
    }

    @Test func baghdadTimesAreInTheRightOrderAndPlace() throws {
        let times = PrayerTimes(date: november1, coordinate: baghdad, method: .jafari, timeZone: iraq).times
        let fajr = clock(try #require(times[.fajr])), sunrise = clock(try #require(times[.sunrise]))
        let dhuhr = clock(try #require(times[.dhuhr])), asr = clock(try #require(times[.asr]))
        let maghrib = clock(try #require(times[.maghrib])), isha = clock(try #require(times[.isha]))
        #expect(fajr < sunrise && sunrise < dhuhr && dhuhr < asr && asr < maghrib && maghrib < isha)
        // 1 November in Baghdad: sunrise 06:20, Dhuhr 11:46, sunset 17:11 (published timetables agree within minutes).
        #expect(abs(dhuhr - 11.77) < 0.1)
        #expect(abs(sunrise - 6.33) < 0.1)
        #expect(maghrib > 17.0 && maghrib < 17.6) // Ja'fari Maghrib is ~15 min after sunset.
    }

    @Test func jafariMaghribIsAfterSunsetMWLIsAt() throws {
        let jafari = PrayerTimes(date: november1, coordinate: baghdad, method: .jafari, timeZone: iraq).times
        let mwl = PrayerTimes(date: november1, coordinate: baghdad, method: .mwl, timeZone: iraq).times
        let gap = try #require(jafari[.maghrib]).timeIntervalSince(try #require(mwl[.maghrib]))
        #expect(gap > 8 * 60 && gap < 25 * 60)
    }

    @Test func qiblaFromBaghdadPointsSouthSouthWest() {
        // The great-circle bearing from Baghdad to the Kaaba is 199.8 degrees.
        #expect(abs(PrayerTimes.qibla(from: baghdad) - 199.8) < 0.5)
    }
}
