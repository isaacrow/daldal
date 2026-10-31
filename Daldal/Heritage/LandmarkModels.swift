import CoreLocation
import CryptoKit
import Foundation
import Observation
import UIKit

/// A 3D model of a monument or place to visit, generated from one Wikimedia Commons photo with TripoSR
/// (scripts/models). The hidden sides are the AI's best guess, so the app labels them as models, not surveys.
nonisolated struct LandmarkModel: Codable, Hashable, Sendable {
    let id: String // Wikidata QID, shared with the heritage catalogue and the city guides
    let file: String
    let bytes: Int
    let sha256: String
    /// The Commons page of the photo it was made from (its author and licence are listed there).
    let photo: String
    let icon: String?
    /// Real height in metres (Wikidata where recorded, otherwise an estimate). The model itself is 1 unit tall.
    let height: Double?

    var photoURL: URL? { URL(string: photo) }
}

/// The landmark models published with the maps (github.com/isaacrow/daldal-maps, release "landmarks").
/// The catalogue and the small map icons come down once and are kept for offline use; each model downloads
/// the first time someone opens it.
@Observable
final class LandmarkModelStore {
    static let base = URL(string: "https://github.com/isaacrow/daldal-maps/releases/download/landmarks-1/")!

    private(set) var models: [String: LandmarkModel] = [:]
    /// Map icons (a 3/4 view of each model), by id, once downloaded.
    private(set) var icons: [String: UIImage] = [:]

    @ObservationIgnored private var loading = false
    @ObservationIgnored private let folder: URL = {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let folder = caches.appending(path: "Landmarks", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder.appending(path: "icons"), withIntermediateDirectories: true)
        return folder
    }()

    func model(for id: String?) -> LandmarkModel? { id.flatMap { models[$0] } }

    /// Models open only on site: within this distance of the place (GPS in old cities is often 30-80 m off).
    static let unlockRadius: CLLocationDistance = 500

    static func isUnlocked(_ place: CLLocationCoordinate2D, from here: CLLocation?) -> Bool {
        guard let here else { return false }
        return here.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) <= unlockRadius
    }

    /// Loads the catalogue (fresh when online, else the saved copy) and the map icons.
    func load() async {
        guard !loading, models.isEmpty else { return }
        loading = true
        defer { loading = false }
        let saved = folder.appending(path: "models.json")
        if let (data, response) = try? await URLSession.shared.data(from: Self.base.appending(path: "models.json")),
           (response as? HTTPURLResponse)?.statusCode == 200,
           (try? JSONDecoder().decode([LandmarkModel].self, from: data)) != nil {
            try? data.write(to: saved, options: .atomic)
        }
        guard let data = try? Data(contentsOf: saved),
              let list = try? JSONDecoder().decode([LandmarkModel].self, from: data) else { return }
        models = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        await loadIcons(list)
    }

    private func loadIcons(_ list: [LandmarkModel]) async {
        let folder = folder.appending(path: "icons")
        let base = Self.base
        var loaded: [String: UIImage] = [:]
        await withTaskGroup(of: (String, Data?).self) { group in
            for model in list {
                guard let icon = model.icon else { continue }
                // Named after the model's fingerprint, so a rebuilt model brings its new picture.
                let file = folder.appending(path: "\(model.sha256.prefix(12))-\(icon)")
                group.addTask {
                    if let data = try? Data(contentsOf: file) { return (model.id, data) }
                    guard let (data, response) = try? await URLSession.shared.data(from: base.appending(path: icon)),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return (model.id, nil) }
                    try? data.write(to: file, options: .atomic)
                    return (model.id, data)
                }
            }
            for await (id, data) in group {
                if let data, let image = UIImage(data: data, scale: 2) { loaded[id] = image }
            }
        }
        icons = loaded
    }

    /// The model on disk, downloading and checking it the first time.
    func localModel(_ model: LandmarkModel) async throws -> URL {
        // Named after the fingerprint: a rebuilt model replaces the cached one.
        let file = folder.appending(path: "\(model.sha256.prefix(12))-\(model.file)")
        if FileManager.default.fileExists(atPath: file.path()) { return file }
        let (temp, response) = try await URLSession.shared.download(from: Self.base.appending(path: model.file))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let data = try Data(contentsOf: temp, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == model.sha256 else { throw URLError(.cannotDecodeContentData) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temp, to: file)
        return file
    }
}
