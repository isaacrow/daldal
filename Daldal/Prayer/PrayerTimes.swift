import CoreLocation
import Foundation

/// Prayer times for a place and day, calculated on the phone from the sun's position (the standard astronomical
/// method used by praytimes.org), so they work offline anywhere in Iraq.
nonisolated struct PrayerTimes: Sendable {
    enum Method: String, CaseIterable, Identifiable, Sendable {
        /// Shia Ithna-Ashari (Leva Institute, Qum): Fajr 16°, Maghrib 4° below the horizon, Isha 14°.
        case jafari
        /// Muslim World League: Fajr 18°, Maghrib at sunset, Isha 17°.
        case mwl

        var id: String { rawValue }
        var fajrAngle: Double { self == .jafari ? 16 : 18 }
        var ishaAngle: Double { self == .jafari ? 14 : 17 }
        /// Maghrib this many degrees below the horizon (nil: at sunset).
        var maghribAngle: Double? { self == .jafari ? 4 : nil }
    }

    enum Prayer: String, CaseIterable, Identifiable, Sendable {
        case fajr, sunrise, dhuhr, asr, maghrib, isha
        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .fajr: "Fajr"
            case .sunrise: "Sunrise"
            case .dhuhr: "Dhuhr"
            case .asr: "Asr"
            case .maghrib: "Maghrib"
            case .isha: "Isha"
            }
        }
    }

    let times: [Prayer: Date]

    init(date: Date, coordinate: CLLocationCoordinate2D, method: Method, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let midnight = calendar.date(from: day) ?? date
        let offset = Double(timeZone.secondsFromGMT(for: midnight)) / 3600
        let lat = coordinate.latitude, lon = coordinate.longitude
        // Julian date at local noon, corrected for longitude.
        let jd = Self.julian(year: day.year ?? 2026, month: day.month ?? 1, day: day.day ?? 1) - lon / (15 * 24)

        func sun(_ fraction: Double) -> (declination: Double, equation: Double) {
            let d = jd + fraction - 2451545.0
            let g = Self.fixAngle(357.529 + 0.98560028 * d)
            let q = Self.fixAngle(280.459 + 0.98564736 * d)
            let l = Self.fixAngle(q + 1.915 * Self.sin(g) + 0.020 * Self.sin(2 * g))
            let e = 23.439 - 0.00000036 * d
            let ra = Self.atan2(Self.cos(e) * Self.sin(l), Self.cos(l)) / 15
            return (Self.asin(Self.sin(e) * Self.sin(l)), q / 15 - Self.fixHour(ra))
        }
        func midDay(_ t: Double) -> Double { Self.fixHour(12 - sun(t).equation) }
        /// When the sun is `angle` degrees below the horizon, before (ccw) or after noon.
        func sunAngleTime(_ angle: Double, _ t: Double, beforeNoon: Bool) -> Double {
            let decl = sun(t).declination
            let x = (-Self.sin(angle) - Self.sin(decl) * Self.sin(lat)) / (Self.cos(decl) * Self.cos(lat))
            let span = Self.acos(max(-1, min(1, x))) / 15
            return midDay(t) + (beforeNoon ? -span : span)
        }
        func asrTime(_ t: Double) -> Double {
            let decl = sun(t).declination
            let angle = -Self.acot(1 + Self.tan(abs(lat - decl))) // Shafi'i, Maliki, Hanbali and Ja'fari: shadow = 1
            return sunAngleTime(angle, t, beforeNoon: false)
        }

        // Rough times as day fractions, refined once.
        var fajr = sunAngleTime(method.fajrAngle, 5 / 24, beforeNoon: true)
        var sunrise = sunAngleTime(0.833, 6 / 24, beforeNoon: true)
        var dhuhr = midDay(12 / 24)
        var asr = asrTime(13 / 24)
        var sunset = sunAngleTime(0.833, 18 / 24, beforeNoon: false)
        var maghrib = method.maghribAngle.map { sunAngleTime($0, 18 / 24, beforeNoon: false) } ?? sunset
        var isha = sunAngleTime(method.ishaAngle, 18 / 24, beforeNoon: false)
        fajr = sunAngleTime(method.fajrAngle, fajr / 24, beforeNoon: true)
        sunrise = sunAngleTime(0.833, sunrise / 24, beforeNoon: true)
        dhuhr = midDay(dhuhr / 24)
        asr = asrTime(asr / 24)
        sunset = sunAngleTime(0.833, sunset / 24, beforeNoon: false)
        maghrib = method.maghribAngle.map { sunAngleTime($0, maghrib / 24, beforeNoon: false) } ?? sunset
        isha = sunAngleTime(method.ishaAngle, isha / 24, beforeNoon: false)

        func clock(_ hours: Double) -> Date {
            midnight.addingTimeInterval((hours + offset - lon / 15) * 3600)
        }
        times = [.fajr: clock(fajr), .sunrise: clock(sunrise), .dhuhr: clock(dhuhr), .asr: clock(asr),
                 .maghrib: clock(maghrib), .isha: clock(isha)]
    }

    /// The next prayer from `now` (sunrise counts as a time, not a prayer).
    func next(after now: Date) -> (Prayer, Date)? {
        Prayer.allCases.filter { $0 != .sunrise }.compactMap { prayer in times[prayer].map { (prayer, $0) } }
            .filter { $0.1 > now }.min { $0.1 < $1.1 }
    }

    // MARK: Qibla

    static let kaaba = CLLocationCoordinate2D(latitude: 21.4225, longitude: 39.8262)

    /// Direction of the Kaaba from a place, in degrees clockwise from true north.
    static func qibla(from c: CLLocationCoordinate2D) -> Double {
        let dLon = kaaba.longitude - c.longitude
        let y = sin(dLon), x = cos(c.latitude) * tan(kaaba.latitude) - sin(c.latitude) * cos(dLon)
        return fixAngle(atan2(y, x))
    }

    // MARK: Degree trigonometry

    private static func julian(year: Int, month: Int, day: Int) -> Double {
        var y = Double(year), m = Double(month)
        if m <= 2 { y -= 1; m += 12 }
        let a = (y / 100).rounded(.down), b = 2 - a + (a / 4).rounded(.down)
        return (365.25 * (y + 4716)).rounded(.down) + (30.6001 * (m + 1)).rounded(.down) + Double(day) + b - 1524.5
    }
    private static func sin(_ d: Double) -> Double { Foundation.sin(d * .pi / 180) }
    private static func cos(_ d: Double) -> Double { Foundation.cos(d * .pi / 180) }
    private static func tan(_ d: Double) -> Double { Foundation.tan(d * .pi / 180) }
    private static func asin(_ x: Double) -> Double { Foundation.asin(x) * 180 / .pi }
    private static func acos(_ x: Double) -> Double { Foundation.acos(x) * 180 / .pi }
    private static func atan2(_ y: Double, _ x: Double) -> Double { Foundation.atan2(y, x) * 180 / .pi }
    private static func acot(_ x: Double) -> Double { Foundation.atan(1 / x) * 180 / .pi }
    private static func fixAngle(_ a: Double) -> Double { let r = a.truncatingRemainder(dividingBy: 360); return r < 0 ? r + 360 : r }
    private static func fixHour(_ h: Double) -> Double { let r = h.truncatingRemainder(dividingBy: 24); return r < 0 ? r + 24 : r }
}
