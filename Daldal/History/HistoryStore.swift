import CoreLocation
import Foundation
import Observation

/// A battle, siege or other event that happened in Iraq before 1950, from the bundled history layer
/// (Wikidata, CC0; descriptions from Wikipedia, CC BY-SA 4.0).
nonisolated struct HistoryEvent: Codable, Identifiable, Hashable, Sendable {
    let id: String // Wikidata QID
    let lat: Double
    let lon: Double
    let kind: String // battle, siege, uprising, massacre, event
    let year: Int
    let name_ar: String?
    let name_en: String?
    let wiki_ar: String?
    let wiki_en: String?
    let summary_ar: String?
    let summary_en: String?

    var location: CLLocation { CLLocation(latitude: lat, longitude: lon) }

    func name(languageCode: String) -> String {
        (languageCode == "ar" ? name_ar : name_en) ?? name_ar ?? name_en ?? id
    }

    func summary(languageCode: String) -> String? {
        languageCode == "ar" ? summary_ar : summary_en
    }

    /// "680" or "539 BC" (and the Arabic forms).
    var yearText: String {
        year < 0 ? String(localized: "\(-year) BC") : String(year)
    }

    func wikipediaURL(languageCode: String) -> URL? {
        // The article in the app's language when there is one, else the other.
        let articles = languageCode == "ar" ? [("ar", wiki_ar), ("en", wiki_en)] : [("en", wiki_en), ("ar", wiki_ar)]
        guard let (lang, title) = articles.first(where: { $0.1 != nil }).map({ ($0.0, $0.1!) }),
              let encoded = title.replacingOccurrences(of: " ", with: "_")
                  .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://\(lang).wikipedia.org/wiki/\(encoded)")
    }
}

@Observable
final class HistoryStore {
    let events: [HistoryEvent]

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "history-events", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([HistoryEvent].self, from: data) else {
            events = []
            return
        }
        events = decoded
    }

    /// Events that happened near a place, oldest first. Only those with a description to show.
    func events(near coordinate: CLLocationCoordinate2D, within radius: CLLocationDistance = 15_000,
                languageCode: String, limit: Int = 7) -> [HistoryEvent] {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let near = events.filter { $0.summary(languageCode: languageCode) != nil && $0.location.distance(from: here) <= radius }
        // Keep the closest ones when a city has many (Baghdad was besieged a dozen times), then tell them in order.
        let closest = near.sorted { $0.location.distance(from: here) < $1.location.distance(from: here) }.prefix(limit)
        return closest.sorted { $0.year < $1.year }
    }
}
