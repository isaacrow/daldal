import CoreLocation

/// A point the user can look at, save, and (from Phase 2) navigate to.
struct Place: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var subtitle: String
    var latitude: Double
    var longitude: Double
    var category: PlaceCategory
    /// Set when this place is a site from the heritage catalogue.
    var heritageID: String? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distance(from location: CLLocation?) -> CLLocationDistance? {
        location.map { CLLocation(latitude: latitude, longitude: longitude).distance(from: $0) }
    }

    /// A place made from a long press before reverse geocoding finishes.
    static func droppedPin(at coordinate: CLLocationCoordinate2D) -> Place {
        Place(
            id: "pin:\(coordinate.latitude),\(coordinate.longitude)",
            name: String(localized: "Dropped pin"),
            subtitle: coordinate.formattedDegrees,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            category: .pin
        )
    }
}

enum PlaceCategory: String, Codable, Sendable {
    case fuel, food, cafe, parking, health, shop, worship, heritage, road, city, pin, other

    var icon: DaldalIcon {
        switch self {
        case .heritage: .heritage
        case .fuel: .fuel
        case .food: .food
        case .cafe: .cafe
        case .parking: .parking
        case .health: .health
        case .shop: .shop
        case .worship: .mosque
        case .road: .road
        case .city: .city
        case .pin, .other: .pin
        }
    }

    /// Maps an OpenStreetMap `key=value` tag to a category.
    init(osmKey: String?, osmValue: String?) {
        switch (osmKey, osmValue) {
        case (_, "fuel"), (_, "charging_station"): self = .fuel
        case (_, "restaurant"), (_, "fast_food"), (_, "food_court"): self = .food
        case (_, "cafe"): self = .cafe
        case (_, "parking"), (_, "parking_space"): self = .parking
        case (_, "hospital"), (_, "clinic"), (_, "pharmacy"), (_, "doctors"): self = .health
        case (_, "place_of_worship"): self = .worship
        case ("historic", _), (_, "archaeological_site"), (_, "monument"), (_, "museum"): self = .heritage
        case ("shop", _), (_, "marketplace"), (_, "mall"): self = .shop
        case ("highway", _): self = .road
        case ("place", _), ("boundary", _): self = .city
        default: self = .other
        }
    }
}

extension CLLocationCoordinate2D {
    var formattedDegrees: String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(5))
        return "\(latitude.formatted(format)), \(longitude.formatted(format))"
    }
}
