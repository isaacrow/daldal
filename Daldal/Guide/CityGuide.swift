import CoreLocation
import Foundation
import Observation

/// A place worth visiting, from the bundled city guides (Wikidata, CC0; descriptions from Wikipedia, CC BY-SA 4.0).
nonisolated struct GuidePlace: Codable, Identifiable, Hashable, Sendable {
    let id: String // Wikidata QID
    let kind: String
    let lat: Double
    let lon: Double
    let name_ar: String?
    let name_en: String?
    let image: String?
    let wiki_ar: String?
    let wiki_en: String?
    let summary_ar: String?
    let summary_en: String?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var imageURL: URL? { image.flatMap(URL.init(string:)) }

    func name(languageCode: String) -> String {
        (languageCode == "ar" ? name_ar : name_en) ?? name_ar ?? name_en ?? id
    }

    /// The description in the app's language only: it's read aloud, and an Arabic voice can't read English well.
    func summary(languageCode: String) -> String? {
        languageCode == "ar" ? summary_ar : summary_en
    }

    func wikipediaURL(languageCode: String) -> URL? {
        let (lang, title) = languageCode == "ar" ? ("ar", wiki_ar) : ("en", wiki_en)
        guard let title, let encoded = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://\(lang).wikipedia.org/wiki/\(encoded)")
    }

    var category: PlaceCategory {
        switch kind {
        case "mosque", "shrine", "church": .worship
        case "market": .shop
        default: .heritage
        }
    }

    func place(languageCode: String) -> Place {
        Place(id: "guide:\(id)", name: name(languageCode: languageCode),
              subtitle: String(localized: "Place to visit"),
              latitude: lat, longitude: lon, category: category, guideID: id)
    }
}

nonisolated struct GuideCity: Codable, Sendable, Identifiable {
    let id: String
    let name_ar: String
    let name_en: String
    let center: [Double] // [lat, lon]
    let places: [GuidePlace]

    func name(languageCode: String) -> String { languageCode == "ar" ? name_ar : name_en }
    var centerLocation: CLLocation { CLLocation(latitude: center[0], longitude: center[1]) }
}

/// The best places to visit in each city, bundled with the app so the guide works offline.
@Observable
final class CityGuideStore {
    let cities: [GuideCity]
    let places: [GuidePlace]

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "city-guides", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([GuideCity].self, from: data) else {
            cities = []
            places = []
            return
        }
        cities = decoded
        // A place can sit inside two overlapping city areas (Najaf and Kufa); keep it once.
        var seen = Set<String>()
        places = decoded.flatMap(\.places).filter { seen.insert($0.id).inserted }
    }

    func place(id: String) -> GuidePlace? { places.first { $0.id == id } }

    /// The guide for the city nearest to a point (the one the user is in, or looking at).
    func city(near coordinate: CLLocationCoordinate2D) -> GuideCity? {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Only cities that have places to show; small towns without entries borrow their nearest neighbour's.
        return cities.filter { !$0.places.isEmpty }
            .min { $0.centerLocation.distance(from: here) < $1.centerLocation.distance(from: here) }
    }
}
