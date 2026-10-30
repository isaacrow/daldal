import CoreLocation
import Foundation

/// A monument or visitor site in Iraq.
///
/// The bundled catalogue (`iraq-heritage.json`) is generated from Wikidata, which is CC0,
/// so it can ship freely. `modelURL` points at a USDZ shown in geographic AR.
struct HeritageSite: Identifiable, Hashable, Codable, Sendable {
    let id: String // Wikidata QID
    let latitude: Double
    let longitude: Double
    let nameAr: String?
    let nameEn: String?
    let imageURL: URL?
    let isWorldHeritage: Bool
    var modelURL: URL?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    func name(languageCode: String) -> String {
        let preferred = languageCode == "ar" ? nameAr : nameEn
        return preferred ?? nameAr ?? nameEn ?? id
    }

    var wikidataURL: URL { URL(string: "https://www.wikidata.org/wiki/\(id)")! }

    /// The Wikimedia Commons page for the image, where its author and licence are listed.
    var imageCreditURL: URL? {
        guard let imageURL,
              let file = imageURL.path().components(separatedBy: "Special:FilePath/").last
        else { return nil }
        return URL(string: "https://commons.wikimedia.org/wiki/File:\(file)")
    }

    func place(languageCode: String) -> Place {
        Place(
            id: "heritage:\(id)",
            name: name(languageCode: languageCode),
            subtitle: isWorldHeritage ? String(localized: "UNESCO World Heritage Site") : String(localized: "Heritage site"),
            latitude: latitude,
            longitude: longitude,
            category: .heritage,
            heritageID: id
        )
    }
}

enum HeritageCatalog {
    static func load(from bundle: Bundle = .main) -> [HeritageSite] {
        guard let url = bundle.url(forResource: "iraq-heritage", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let sites = try? JSONDecoder().decode([HeritageSite].self, from: data)
        else {
            assertionFailure("iraq-heritage.json is missing or invalid")
            return []
        }
        return sites
    }
}
