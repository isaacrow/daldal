import CoreLocation
import Foundation
import SQLite3

/// Searches the pack's SQLite FTS5 index (`scripts/pack/build_search_index.py`). Works with no connection.
final class OfflineSearchService: PlaceSearchService {
    // Only the main actor uses the handle while the service lives; deinit closes it after the last use,
    // when no other access is possible.
    nonisolated(unsafe) private var db: OpaquePointer?
    private let languageCode: String

    init(index: URL, languageCode: String) throws {
        self.languageCode = languageCode
        guard sqlite3_open_v2(index.path(), &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw URLError(.cannotOpenFile)
        }
    }

    deinit { sqlite3_close(db) }

    func search(_ query: String, near: CLLocationCoordinate2D?) async throws -> [Place] {
        guard let match = Self.ftsQuery(query) else { return [] }
        let sql = """
            SELECT id, name, name_ar, name_en, subtitle, lat, lon, osm_key, osm_value, bm25(places)
            FROM places WHERE terms MATCH ? ORDER BY bm25(places) LIMIT 60
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw URLError(.cannotDecodeContentData) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, match, -1, Self.transient)

        var scored: [(Place, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = Self.text(statement, 1) ?? ""
            let localized = languageCode == "ar" ? Self.text(statement, 2) : Self.text(statement, 3)
            let place = Place(
                id: Self.text(statement, 0) ?? UUID().uuidString,
                name: localized.flatMap { $0.isEmpty ? nil : $0 } ?? name,
                subtitle: Self.text(statement, 4) ?? "",
                latitude: sqlite3_column_double(statement, 5),
                longitude: sqlite3_column_double(statement, 6),
                category: PlaceCategory(osmKey: Self.text(statement, 7), osmValue: Self.text(statement, 8))
            )
            // bm25 is negative; lower is better. Nearby places get a gentle boost, never a hard cut.
            var score = sqlite3_column_double(statement, 9)
            if let near {
                let km = CLLocation(latitude: place.latitude, longitude: place.longitude)
                    .distance(from: CLLocation(latitude: near.latitude, longitude: near.longitude)) / 1000
                score += log1p(km) * 0.6
            }
            scored.append((place, score))
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(20).map(\.0)
    }

    func reverse(_ coordinate: CLLocationCoordinate2D) async throws -> Place? {
        nil // The text index has no spatial index; reverse geocoding stays online.
    }

    /// Turns what the user typed into an FTS5 query: every word must match, the last one as a prefix.
    static func ftsQuery(_ text: String) -> String? {
        let words = ArabicSearchNormalizer.normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { index, word in
            "\"\(word)\"" + (index == words.count - 1 ? "*" : "")
        }.joined(separator: " ")
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}

/// Offline first when the Iraq pack is installed (instant, free, works in dead zones), online otherwise.
final class HybridSearchService: PlaceSearchService {
    private let online: any PlaceSearchService
    /// Downloaded cities' indexes, the city the user is in first.
    private let offline: () -> [any PlaceSearchService]

    init(online: any PlaceSearchService, offline: @escaping () -> [any PlaceSearchService]) {
        self.online = online
        self.offline = offline
    }

    /// Offline first when cities are downloaded (instant, free, works in dead zones), online otherwise.
    func search(_ query: String, near: CLLocationCoordinate2D?) async throws -> [Place] {
        var found: [Place] = []
        var seen = Set<String>()
        for index in offline() {
            for place in (try? await index.search(query, near: near)) ?? [] where seen.insert(place.id).inserted {
                found.append(place)
            }
        }
        if !found.isEmpty { return Array(found.prefix(20)) }
        return try await online.search(query, near: near)
    }

    func reverse(_ coordinate: CLLocationCoordinate2D) async throws -> Place? {
        try await online.reverse(coordinate)
    }
}

/// Folds text so Arabic matches the way people type it. Must match `normalize()` in
/// `scripts/pack/build_search_index.py`, which applies the same rules to the index.
enum ArabicSearchNormalizer {
    private static let fold: [Character: String] = [
        "أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ى": "ي", "ة": "ه", "ؤ": "و", "ئ": "ي", "ـ": "",
    ]

    static func normalize(_ text: String) -> String {
        // Decompose, then drop combining marks: harakat, shadda, and Latin accents.
        let scalars = text.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { $0.properties.generalCategory != .nonspacingMark }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
            .map { fold[$0] ?? String($0) }
            .joined()
            .lowercased()
    }
}
