import CoreLocation
import Foundation

/// Kinds of everyday places people look for around them, matched to OpenStreetMap tags.
enum NearbyCategory: String, CaseIterable, Identifiable, Sendable {
    case toilets, restaurant, cafe, fuel, pharmacy, hospital, atm, mosque, parking, hotel, supermarket

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .toilets: "Toilets"
        case .restaurant: "Restaurants"
        case .cafe: "Cafés"
        case .fuel: "Fuel"
        case .pharmacy: "Pharmacy"
        case .hospital: "Hospital"
        case .atm: "ATM"
        case .mosque: "Mosque"
        case .parking: "Parking"
        case .hotel: "Hotel"
        case .supermarket: "Supermarket"
        }
    }

    var category: PlaceCategory {
        switch self {
        case .restaurant: .food
        case .cafe: .cafe
        case .fuel: .fuel
        case .pharmacy, .hospital: .health
        case .mosque: .worship
        case .parking: .parking
        case .supermarket, .atm: .shop
        case .toilets, .hotel: .other
        }
    }

    var icon: DaldalIcon {
        switch self {
        case .toilets: .toilet
        case .hotel: .hotel
        case .atm: .atm
        default: category.icon
        }
    }

    /// Overpass tag filters (any of them matches).
    var filters: [String] {
        switch self {
        case .toilets: ["[amenity=toilets]"]
        case .restaurant: ["[amenity=restaurant]", "[amenity=fast_food]"]
        case .cafe: ["[amenity=cafe]"]
        case .fuel: ["[amenity=fuel]"]
        case .pharmacy: ["[amenity=pharmacy]"]
        case .hospital: ["[amenity=hospital]", "[amenity=clinic]"]
        case .atm: ["[amenity=atm]", "[amenity=bank]"]
        case .mosque: ["[amenity=place_of_worship][religion=muslim]"]
        case .parking: ["[amenity=parking]"]
        case .hotel: ["[tourism=hotel]", "[tourism=guest_house]"]
        case .supermarket: ["[shop=supermarket]", "[shop=convenience]"]
        }
    }

    /// Matches what someone typed or said ("wc", "toilet", "حمام", "مطعم") to a category.
    init?(spoken text: String) {
        let t = text.lowercased()
        let words: [(NearbyCategory, [String])] = [
            (.toilets, ["toilet", "wc", "restroom", "bathroom", "حمام", "مرافق", "دورة مياه", "تواليت"]),
            (.restaurant, ["restaurant", "food", "eat", "مطعم", "اكل", "أكل", "طعام"]),
            (.cafe, ["cafe", "café", "coffee", "مقهى", "قهوة", "كافيه", "چاي", "شاي"]),
            (.fuel, ["fuel", "petrol", "gas station", "benzin", "وقود", "بنزين", "محطة"]),
            (.pharmacy, ["pharmacy", "chemist", "صيدلية"]),
            (.hospital, ["hospital", "clinic", "doctor", "مستشفى", "مستوصف", "طبيب"]),
            (.atm, ["atm", "bank", "cash", "صراف", "مصرف", "بنك"]),
            (.mosque, ["mosque", "pray", "جامع", "مسجد", "صلاة"]),
            (.parking, ["parking", "park the car", "موقف", "كراج", "باركنك"]),
            (.hotel, ["hotel", "stay", "فندق", "نزل"]),
            (.supermarket, ["supermarket", "grocery", "market", "سوبر", "ماركت", "اسواق", "أسواق"]),
        ]
        guard let match = words.first(where: { $0.1.contains { t.contains($0) } }) else { return nil }
        self = match.0
    }
}

/// Live OpenStreetMap data through the public Overpass API: nearby places by category, and road features
/// (stop signs, speed cameras) around a point.
enum Overpass {
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    struct Element: Decodable, Sendable {
        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let center: Center?
        let tags: [String: String]?

        struct Center: Decodable, Sendable { let lat: Double; let lon: Double }

        var coordinate: CLLocationCoordinate2D? {
            if let lat, let lon { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
            return center.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
    }

    private struct Response: Decodable { let elements: [Element] }

    static func run(_ query: String) async throws -> [Element] {
        var request = URLRequest(url: endpoint, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue(SearchConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Response.self, from: data).elements
    }

    /// The nearest places of a kind, widening the search from 2 km up to 15 km until something turns up.
    static func nearby(_ category: NearbyCategory, around here: CLLocationCoordinate2D, languageCode: String) async throws -> [Place] {
        for radius in [2_000, 6_000, 15_000] {
            let around = "(around:\(radius),\(here.latitude),\(here.longitude))"
            let parts = category.filters.flatMap { ["node\($0)\(around);", "way\($0)\(around);"] }.joined()
            let elements = try await run("[out:json][timeout:20];(\(parts));out center 60;")
            let places = elements.compactMap { place(from: $0, category: category, languageCode: languageCode) }
            if !places.isEmpty {
                let origin = CLLocation(latitude: here.latitude, longitude: here.longitude)
                return places.sorted { ($0.distance(from: origin) ?? 0) < ($1.distance(from: origin) ?? 0) }.prefix(30).map { $0 }
            }
        }
        return []
    }

    static func place(from element: Element, category: NearbyCategory, languageCode: String) -> Place? {
        guard let coordinate = element.coordinate else { return nil }
        let tags = element.tags ?? [:]
        let name = (languageCode == "ar" ? tags["name:ar"] : tags["name:en"]) ?? tags["name"]
            ?? String(localized: category.title)
        let street = tags["addr:street"] ?? tags["addr:city"] ?? ""
        return Place(id: "osm:\(element.type)/\(element.id)", name: name,
                     subtitle: street.isEmpty ? String(localized: category.title) : street,
                     latitude: coordinate.latitude, longitude: coordinate.longitude, category: category.category)
    }
}
