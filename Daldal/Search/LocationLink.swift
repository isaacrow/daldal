import CoreLocation
import Foundation

/// Reads a location out of whatever another app copied or shared: plain coordinates ("33.31, 44.36"),
/// geo: URIs, Google Maps, Waze, Apple Maps and Daldal links. Short links (maps.app.goo.gl) are followed.
enum LocationLink {
    struct Found: Equatable {
        let coordinate: CLLocationCoordinate2D
        let name: String?

        static func == (a: Found, b: Found) -> Bool {
            a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude && a.name == b.name
        }
    }

    /// Parses without the network. Nil when the text has no recognisable location.
    static func parse(_ text: String) -> Found? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Daldal's own links: daldal://place?lat=..&lon=..&name=..
        if let url = URL(string: text), url.scheme == "daldal", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let lat = items.first(where: { $0.name == "lat" })?.value.flatMap(Double.init),
           let lon = items.first(where: { $0.name == "lon" })?.value.flatMap(Double.init) {
            return found(lat, lon, name: items.first { $0.name == "name" }?.value)
        }

        // A URL somewhere in the text (shared messages often wrap it in words).
        if let url = firstURL(in: text) {
            let decoded = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let name = items.first { ["q", "query", "name", "address"].contains($0.name) }?.value
                .flatMap { pair(in: $0) == nil ? $0.replacingOccurrences(of: "+", with: " ") : nil }
            // Google: /@lat,lon,zoom or !3dLAT!4dLON; Waze/Apple: ll=lat,lon; others: q=lat,lon / query= / daddr= / destination=
            if let match = firstMatch(#"!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)"#, in: decoded) { return found(match.0, match.1, name: name) }
            if let match = firstMatch(#"@(-?\d+\.\d+),(-?\d+\.\d+)"#, in: decoded) { return found(match.0, match.1, name: name) }
            // Daldal's web links (isaacrow.github.io/daldal/?lat=..&lon=..&name=..)
            if let lat = items.first(where: { $0.name == "lat" })?.value.flatMap(Double.init),
               let lon = items.first(where: { $0.name == "lon" })?.value.flatMap(Double.init) {
                return found(lat, lon, name: items.first { $0.name == "name" }?.value)
            }
            if let lat = items.first(where: { $0.name == "mlat" })?.value.flatMap(Double.init),
               let lon = items.first(where: { $0.name == "mlon" })?.value.flatMap(Double.init) {
                return found(lat, lon, name: name) // OpenStreetMap links
            }
            for key in ["ll", "q", "query", "daddr", "destination", "sll", "center"] {
                if let value = items.first(where: { $0.name == key })?.value, let p = pair(in: value) {
                    return found(p.0, p.1, name: name)
                }
            }
        }

        // geo:lat,lon or bare coordinates, with optional N/E letters or degree marks.
        let cleaned = text.replacingOccurrences(of: "geo:", with: "")
        if let p = pair(in: cleaned) { return found(p.0, p.1, name: nil) }
        return nil
    }

    /// Like `parse`, but also follows short links (maps.app.goo.gl, goo.gl/maps, waze.com/ul/h…) to their full form.
    static func resolve(_ text: String) async -> Found? {
        if let direct = parse(text) { return direct }
        guard let url = firstURL(in: text), let host = url.host(),
              ["maps.app.goo.gl", "goo.gl", "g.co", "waze.com", "www.waze.com", "maps.apple"].contains(where: { host.contains($0) }) else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request), let final = response.url else { return nil }
        return parse(final.absoluteString)
    }

    /// Daldal's web page for a place: a map with "Open in Daldal" (and Google Maps for people without the app).
    /// Every app shows it as an ordinary link, and Daldal reads it back when pasted.
    static func shareURL(for coordinate: CLLocationCoordinate2D, name: String? = nil) -> URL {
        var components = URLComponents(string: "https://isaacrow.github.io/daldal/")!
        components.queryItems = [URLQueryItem(name: "lat", value: String(format: "%.6f", coordinate.latitude)),
                                 URLQueryItem(name: "lon", value: String(format: "%.6f", coordinate.longitude))]
            + (name.map { [URLQueryItem(name: "name", value: $0)] } ?? [])
        return components.url!
    }

    // MARK: Helpers

    private static func found(_ lat: Double, _ lon: Double, name: String?) -> Found? {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard CLLocationCoordinate2DIsValid(coordinate), abs(lat) > 0.0001 || abs(lon) > 0.0001 else { return nil }
        return Found(coordinate: coordinate, name: name?.trimmingCharacters(in: .whitespaces).nilIfEmpty)
    }

    private static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.url
    }

    /// "33.3152, 44.3661", "33.3152N 44.3661E", "33.3152° N, 44.3661° E".
    private static func pair(in text: String) -> (Double, Double)? {
        let pattern = #"(-?\d{1,2}\.\d{3,})\s*°?\s*([NS])?\s*[, ]\s*(-?\d{1,3}\.\d{3,})\s*°?\s*([EW])?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let latRange = Range(m.range(at: 1), in: text), let lonRange = Range(m.range(at: 3), in: text),
              var lat = Double(text[latRange]), var lon = Double(text[lonRange]) else { return nil }
        if let r = Range(m.range(at: 2), in: text), text[r].uppercased() == "S" { lat = -abs(lat) }
        if let r = Range(m.range(at: 4), in: text), text[r].uppercased() == "W" { lon = -abs(lon) }
        return (lat, lon)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> (Double, Double)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text),
              let lat = Double(text[a]), let lon = Double(text[b]) else { return nil }
        return (lat, lon)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
