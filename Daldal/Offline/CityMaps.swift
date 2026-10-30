import CoreLocation
import CryptoKit
import Foundation
import Observation

enum CityMapsConfig {
    /// Built weekly by github.com/isaacrow/daldal-maps from OpenStreetMap. "latest" always points at the newest build.
    static let catalogURL = URL(string: "https://github.com/isaacrow/daldal-maps/releases/latest/download/catalog.json")!
    static let backgroundSessionID = "app.daldal.ios.citymaps"
}

/// What the maps repo publishes: every city with its area and files. Written by `write_catalog.py`.
nonisolated struct CityCatalog: Codable, Sendable, Equatable {
    struct File: Codable, Sendable, Equatable {
        let path: String // local file name: map.pmtiles, routing.tar or search.sqlite
        let url: URL
        let bytes: Int64
        let sha256: String
    }

    struct City: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let name_ar: String
        let name_en: String
        let center: [Double] // [lat, lon]
        let bbox: [Double] // [minLon, minLat, maxLon, maxLat]
        let files: [File]

        var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
        func name(languageCode: String) -> String { languageCode == "ar" ? name_ar : name_en }

        var centerCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: center[0], longitude: center[1])
        }
    }

    let version: String
    let cities: [City]
}

/// A downloaded city's files, as the map, router and search see them.
nonisolated struct InstalledCity: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let version: String
    let bbox: [Double]
    let directory: URL

    var mapTiles: URL { directory.appending(path: "map.pmtiles") }
    var routingTiles: URL { directory.appending(path: "routing.tar") }
    var searchIndex: URL { directory.appending(path: "search.sqlite") }

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        bbox.count == 4 && (bbox[0]...bbox[2]).contains(c.longitude) && (bbox[1]...bbox[3]).contains(c.latitude)
    }
}

/// Downloads, verifies, installs and removes city maps.
///
/// Uses a background URLSession, so downloads keep going when the app is closed. Files land in a
/// staging folder and a city only becomes usable after every file's SHA-256 matches the catalog.
@Observable
final class CityMapsStore: NSObject {
    enum CityState: Equatable {
        case available
        case downloading(received: Int64, total: Int64)
        case verifying
        case installed
        case failed(String)
    }

    private(set) var catalog: CityCatalog?
    private(set) var installed: [String: InstalledCity] = [:]
    private(set) var states: [String: CityState] = [:]
    private(set) var catalogError: String?
    private(set) var isLoadingCatalog = false

    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?
    @ObservationIgnored private var active: [String: CityCatalog.City] = [:]
    @ObservationIgnored private var received: [String: [String: Int64]] = [:]
    @ObservationIgnored private var pending: [String: Set<String>] = [:]
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: CityMapsConfig.backgroundSessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private static let installedKey = "citymaps.installed.v1"

    nonisolated static var root: URL {
        URL.applicationSupportDirectory.appending(path: "CityMaps", directoryHint: .isDirectory)
    }

    nonisolated static func staging(_ cityID: String, _ version: String) -> URL {
        root.appending(path: "staging-\(cityID)-\(version)", directoryHint: .isDirectory)
    }

    /// Every downloaded city, in a stable order.
    var installedCities: [InstalledCity] { installed.values.sorted { $0.id < $1.id } }

    func state(of cityID: String) -> CityState {
        states[cityID] ?? (installed[cityID] != nil ? .installed : .available)
    }

    /// Whether a newer build of an installed city exists in the catalog.
    func hasUpdate(_ cityID: String) -> Bool {
        guard let installed = installed[cityID], let catalog else { return false }
        return installed.version != catalog.version && catalog.cities.contains { $0.id == cityID }
    }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.installedKey),
           let saved = try? JSONDecoder().decode([String: InstalledCity].self, from: data) {
            // Rebuild the directory from the current container: the app's sandbox path can change on update.
            installed = saved.reduce(into: [:]) { result, entry in
                let city = entry.value
                let directory = Self.root.appending(path: "\(city.id)/\(city.version)", directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: directory.path()) {
                    result[entry.key] = InstalledCity(id: city.id, version: city.version, bbox: city.bbox, directory: directory)
                }
            }
        }
        Task { await resumeInterruptedDownloads() }
    }

    // MARK: Public actions

    func reconnectBackgroundSession() {
        _ = session
    }

    func loadCatalog() async {
        isLoadingCatalog = catalog == nil // Only show a spinner when there's nothing to show yet.
        defer { isLoadingCatalog = false }
        do {
            // The query defeats any cache between us and GitHub; "latest" moves every week.
            let fresh = CityMapsConfig.catalogURL.appending(queryItems: [URLQueryItem(name: "t", value: String(Int(Date.now.timeIntervalSince1970)))])
            var request = URLRequest(url: fresh)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            catalog = try JSONDecoder().decode(CityCatalog.self, from: data)
            catalogError = nil
        } catch {
            catalogError = (error as? URLError)?.code == .notConnectedToInternet
                ? String(localized: "No internet connection. Connect to see the cities you can download.")
                : String(localized: "The list of city maps isn't available right now. Try again in a moment.")
        }
    }

    func download(_ city: CityCatalog.City) async {
        guard let version = catalog?.version else { return }
        do {
            try ensureFreeSpace(for: city.totalBytes)
            try await start(city, version: version)
        } catch {
            states[city.id] = .failed(Self.describe(error, city: city))
        }
    }

    func delete(_ cityID: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription?.hasPrefix("\(cityID)|") == true }.forEach { $0.cancel() }
        }
        try? FileManager.default.removeItem(at: Self.root.appending(path: cityID, directoryHint: .isDirectory))
        installed[cityID] = nil
        states[cityID] = nil
        active[cityID] = nil
        pending[cityID] = nil
        saveInstalled()
    }

    /// The downloaded city that covers a point, if any.
    func city(containing coordinate: CLLocationCoordinate2D) -> InstalledCity? {
        installedCities.first { $0.contains(coordinate) }
    }

    // MARK: Download

    private func ensureFreeSpace(for bytes: Int64) throws {
        let values = try URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? .max
        if available < bytes + 200_000_000 { throw CityMapsError.notEnoughSpace(needed: bytes) }
    }

    private func start(_ city: CityCatalog.City, version: String) async throws {
        let staging = Self.staging(city.id, version)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try JSONEncoder().encode(city).write(to: staging.appending(path: "city.json"))
        try Data(version.utf8).write(to: staging.appending(path: "version"))
        active[city.id] = city

        let running = Set(await session.allTasks.compactMap(\.taskDescription))
        received[city.id] = [:]
        pending[city.id] = []
        for file in city.files {
            let destination = staging.appending(path: file.path)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            if size == file.bytes {
                received[city.id, default: [:]][file.path] = file.bytes // Finished in an earlier attempt.
                continue
            }
            pending[city.id, default: []].insert(file.path)
            let description = "\(city.id)|\(version)|\(file.path)"
            if !running.contains(description) {
                let task = session.downloadTask(with: file.url)
                task.taskDescription = description
                task.countOfBytesClientExpectsToReceive = file.bytes
                task.resume()
            }
        }
        publishProgress(city.id)
        if pending[city.id, default: []].isEmpty { await finish(city.id, version: version) }
    }

    private func resumeInterruptedDownloads() async {
        let fm = FileManager.default
        let staged = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        for folder in staged where folder.lastPathComponent.hasPrefix("staging-") {
            guard let data = try? Data(contentsOf: folder.appending(path: "city.json")),
                  let city = try? JSONDecoder().decode(CityCatalog.City.self, from: data),
                  let version = try? String(contentsOf: folder.appending(path: "version"), encoding: .utf8)
            else { continue }
            try? await start(city, version: version)
        }
    }

    private func publishProgress(_ cityID: String) {
        guard let city = active[cityID] else { return }
        states[cityID] = .downloading(received: received[cityID, default: [:]].values.reduce(0, +), total: city.totalBytes)
    }

    private func fileFinished(_ cityID: String, version: String, path: String) {
        guard let city = active[cityID] else { return }
        if let bytes = city.files.first(where: { $0.path == path })?.bytes { received[cityID, default: [:]][path] = bytes }
        pending[cityID]?.remove(path)
        publishProgress(cityID)
        if pending[cityID]?.isEmpty == true { Task { await finish(cityID, version: version) } }
    }

    private func fileFailed(_ cityID: String, error: any Error) {
        guard let city = active[cityID], pending[cityID]?.isEmpty == false else { return }
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription?.hasPrefix("\(cityID)|") == true }.forEach { $0.cancel() }
        }
        states[cityID] = .failed(Self.describe(error, city: city))
    }

    // MARK: Verify and install

    private func finish(_ cityID: String, version: String) async {
        guard let city = active[cityID] else { return }
        states[cityID] = .verifying
        let staging = Self.staging(cityID, version)
        let bad = await Self.corruptFiles(in: staging, files: city.files)
        guard bad.isEmpty else {
            for path in bad { try? FileManager.default.removeItem(at: staging.appending(path: path)) }
            states[cityID] = .failed(String(localized: "Some map files were damaged in transfer. Tap Retry to download them again."))
            return
        }
        do {
            let fm = FileManager.default
            let cityFolder = Self.root.appending(path: cityID, directoryHint: .isDirectory)
            var directory = cityFolder.appending(path: version, directoryHint: .isDirectory)
            try fm.createDirectory(at: cityFolder, withIntermediateDirectories: true)
            try? fm.removeItem(at: directory)
            try fm.moveItem(at: staging, to: directory)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true // Re-downloadable, so keep it out of iCloud backups.
            try directory.setResourceValues(values)
            // Remove the city's older builds only after the new one is in place.
            for old in try fm.contentsOfDirectory(at: cityFolder, includingPropertiesForKeys: nil)
            where old.lastPathComponent != version {
                try? fm.removeItem(at: old)
            }
            installed[cityID] = InstalledCity(id: cityID, version: version, bbox: city.bbox, directory: directory)
            states[cityID] = nil
            active[cityID] = nil
            saveInstalled()
        } catch {
            states[cityID] = .failed(Self.describe(error, city: city))
        }
    }

    private func saveInstalled() {
        if let data = try? JSONEncoder().encode(installed) {
            UserDefaults.standard.set(data, forKey: Self.installedKey)
        }
    }

    @concurrent
    private static func corruptFiles(in directory: URL, files: [CityCatalog.File]) async -> [String] {
        files.filter { file in
            guard let handle = try? FileHandle(forReadingFrom: directory.appending(path: file.path)) else { return true }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined() != file.sha256
        }.map(\.path)
    }

    private static func describe(_ error: any Error, city: CityCatalog.City) -> String {
        if case CityMapsError.notEnoughSpace(let needed) = error {
            let size = needed.formatted(.byteCount(style: .file))
            return String(localized: "Not enough free space. This city needs about \(size).")
        }
        if (error as? URLError)?.code == .notConnectedToInternet {
            return String(localized: "No internet connection. The download continues when you're back online.")
        }
        return String(localized: "The download didn't finish. Tap Retry.")
    }
}

enum CityMapsError: Error {
    case notEnoughSpace(needed: Int64)
}

// MARK: URLSessionDownloadDelegate

extension CityMapsStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (cityID, version, path) = Self.parse(downloadTask.taskDescription) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { @MainActor in self.fileFailed(cityID, error: URLError(.badServerResponse)) }
            return
        }
        // The temporary file is deleted when this method returns, so move it synchronously.
        let destination = Self.staging(cityID, version).appending(path: path)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            Task { @MainActor in self.fileFinished(cityID, version: version, path: path) }
        } catch {
            Task { @MainActor in self.fileFailed(cityID, error: error) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (cityID, _, path) = Self.parse(downloadTask.taskDescription) else { return }
        Task { @MainActor in
            guard self.pending[cityID]?.contains(path) == true else { return }
            self.received[cityID, default: [:]][path] = totalBytesWritten
            self.publishProgress(cityID)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, (error as? URLError)?.code != .cancelled,
              let (cityID, _, _) = Self.parse(task.taskDescription) else { return }
        Task { @MainActor in self.fileFailed(cityID, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    /// Task descriptions are "cityID|version|file".
    nonisolated private static func parse(_ description: String?) -> (String, String, String)? {
        guard let parts = description?.split(separator: "|", maxSplits: 2), parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }
}
