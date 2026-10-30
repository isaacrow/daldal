import CryptoKit
import Foundation
import Observation
import UIKit

enum PackConfig {
    /// Output of `scripts/pack/build-iraq-pack.sh`, uploaded to our CDN. Replace before shipping.
    static let manifestURL = URL(string: "https://cdn.example.com/packs/iraq/manifest.json")!
    static let backgroundSessionID = "app.daldal.ios.packs"
}

/// Describes one published version of the Iraq pack. Written by `scripts/pack/write_manifest.py`.
nonisolated struct PackManifest: Codable, Sendable, Equatable {
    struct File: Codable, Sendable, Equatable {
        let path: String
        let url: URL
        let bytes: Int64
        let sha256: String
    }
    let id: String
    let version: String
    let files: [File]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

/// The installed pack's files, as the map, router and search see them.
nonisolated struct InstalledPack: Sendable, Equatable {
    let version: String
    let directory: URL

    var mapTiles: URL { directory.appending(path: "iraq.pmtiles") }
    var routingTiles: URL { directory.appending(path: "routing.tar") }
    var searchIndex: URL { directory.appending(path: "search.sqlite") }
    var fontsDirectory: URL { directory.appending(path: "fonts", directoryHint: .isDirectory) }
}

/// Downloads, verifies, installs and removes the offline Iraq pack.
///
/// Uses a background URLSession, so a 1 GB download keeps going when the app is closed.
/// Files land in a staging folder and only become live after every SHA-256 matches.
@Observable
final class OfflinePackManager: NSObject {
    enum State: Equatable {
        case notInstalled
        case checking
        case downloading(received: Int64, total: Int64)
        case verifying
        case installed
        case failed(String)
    }

    private(set) var state: State = .notInstalled
    private(set) var installed: InstalledPack?
    private(set) var updateAvailable = false
    /// Size of the latest published pack, once known.
    private(set) var publishedBytes: Int64?

    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?
    @ObservationIgnored private var manifest: PackManifest?
    @ObservationIgnored private var received: [String: Int64] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: PackConfig.backgroundSessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private static let versionKey = "pack.iraq.version"

    nonisolated static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Packs/iraq", directoryHint: .isDirectory)
    }

    nonisolated static func stagingDirectory(_ version: String) -> URL {
        root.appending(path: "staging-\(version)", directoryHint: .isDirectory)
    }

    override init() {
        super.init()
        if let version = UserDefaults.standard.string(forKey: Self.versionKey) {
            let directory = Self.root.appending(path: version, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: directory.path()) {
                installed = InstalledPack(version: version, directory: directory)
                state = .installed
            }
        }
        Task { await resumeInterruptedDownload() }
    }

    // MARK: Public actions

    /// Recreates the background session so iOS can deliver events for downloads that ran while we were closed.
    func reconnectBackgroundSession() {
        _ = session
    }

    func download() async {
        state = .checking
        do {
            let latest = try await fetchManifest()
            try ensureFreeSpace(for: latest)
            try await start(latest)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    func checkForUpdate() async {
        guard let latest = try? await fetchManifest() else { return }
        publishedBytes = latest.totalBytes
        updateAvailable = installed.map { $0.version != latest.version } ?? false
    }

    func delete() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        try? FileManager.default.removeItem(at: Self.root)
        UserDefaults.standard.removeObject(forKey: Self.versionKey)
        installed = nil
        manifest = nil
        pending = []
        state = .notInstalled
    }

    // MARK: Download

    private func fetchManifest() async throws -> PackManifest {
        var request = URLRequest(url: PackConfig.manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let manifest = try JSONDecoder().decode(PackManifest.self, from: data)
        publishedBytes = manifest.totalBytes
        return manifest
    }

    private func ensureFreeSpace(for manifest: PackManifest) throws {
        let values = try URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? .max
        // Room for the pack plus the old version while the new one is verified.
        if available < manifest.totalBytes + (installed == nil ? 0 : manifest.totalBytes / 2) + 200_000_000 {
            throw PackError.notEnoughSpace(needed: manifest.totalBytes)
        }
    }

    private func start(_ manifest: PackManifest) async throws {
        let staging = Self.stagingDirectory(manifest.version)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: staging.appending(path: "manifest.json"))
        self.manifest = manifest

        let running = Set(await session.allTasks.compactMap(\.taskDescription))
        received = [:]
        pending = []
        for file in manifest.files {
            let destination = staging.appending(path: file.path)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            if size == file.bytes {
                received[file.path] = file.bytes // Finished in an earlier attempt.
                continue
            }
            pending.insert(file.path)
            let description = "\(manifest.version)|\(file.path)"
            if !running.contains(description) {
                let task = session.downloadTask(with: file.url)
                task.taskDescription = description
                task.countOfBytesClientExpectsToReceive = file.bytes
                task.resume()
            }
        }
        publishProgress()
        if pending.isEmpty { await finish() }
    }

    private func resumeInterruptedDownload() async {
        let fm = FileManager.default
        guard let staged = try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix("staging-") }),
              let data = try? Data(contentsOf: staged.appending(path: "manifest.json")),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: data)
        else { return }
        try? await start(manifest)
    }

    private func publishProgress() {
        guard let manifest else { return }
        state = .downloading(received: received.values.reduce(0, +), total: manifest.totalBytes)
    }

    private func fileFinished(_ path: String, version: String) {
        guard version == manifest?.version else { return }
        if let bytes = manifest?.files.first(where: { $0.path == path })?.bytes { received[path] = bytes }
        pending.remove(path)
        publishProgress()
        if pending.isEmpty { Task { await finish() } }
    }

    private func fileFailed(_ path: String, error: any Error) {
        guard pending.contains(path) else { return }
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        state = .failed(Self.describe(error))
    }

    // MARK: Verify and install

    private func finish() async {
        guard let manifest else { return }
        state = .verifying
        let staging = Self.stagingDirectory(manifest.version)
        let bad = await Self.corruptFiles(in: staging, manifest: manifest)
        guard bad.isEmpty else {
            for path in bad { try? FileManager.default.removeItem(at: staging.appending(path: path)) }
            state = .failed(String(localized: "Some map files were damaged in transfer. Tap Retry to download them again."))
            return
        }
        do {
            let fm = FileManager.default
            var installedDirectory = Self.root.appending(path: manifest.version, directoryHint: .isDirectory)
            try? fm.removeItem(at: installedDirectory)
            try fm.moveItem(at: staging, to: installedDirectory)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true // Re-downloadable, so keep it out of iCloud backups.
            try installedDirectory.setResourceValues(values)

            // Remove older versions only after the new one is in place.
            for old in try fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)
            where old.lastPathComponent != manifest.version {
                try? fm.removeItem(at: old)
            }
            UserDefaults.standard.set(manifest.version, forKey: Self.versionKey)
            installed = InstalledPack(version: manifest.version, directory: installedDirectory)
            updateAvailable = false
            state = .installed
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    @concurrent
    private static func corruptFiles(in directory: URL, manifest: PackManifest) async -> [String] {
        manifest.files.filter { file in
            guard let handle = try? FileHandle(forReadingFrom: directory.appending(path: file.path)) else { return true }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return hex != file.sha256
        }.map(\.path)
    }

    private static func describe(_ error: any Error) -> String {
        if case PackError.notEnoughSpace(let needed) = error {
            let size = needed.formatted(.byteCount(style: .file))
            return String(localized: "Not enough free space. The Iraq map needs about \(size).")
        }
        if (error as? URLError)?.code == .notConnectedToInternet {
            return String(localized: "No internet connection. The download continues when you're back online.")
        }
        return String(localized: "The download didn't finish. Tap Retry.")
    }
}

enum PackError: Error {
    case notEnoughSpace(needed: Int64)
}

// MARK: URLSessionDownloadDelegate

extension OfflinePackManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (version, path) = Self.parse(downloadTask.taskDescription) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { @MainActor in self.fileFailed(path, error: URLError(.badServerResponse)) }
            return
        }
        // The temporary file is deleted when this method returns, so move it synchronously.
        let destination = Self.stagingDirectory(version).appending(path: path)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            Task { @MainActor in self.fileFinished(path, version: version) }
        } catch {
            Task { @MainActor in self.fileFailed(path, error: error) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (version, path) = Self.parse(downloadTask.taskDescription) else { return }
        Task { @MainActor in
            guard version == self.manifest?.version, self.pending.contains(path) else { return }
            self.received[path] = totalBytesWritten
            self.publishProgress()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, (error as? URLError)?.code != .cancelled,
              let (_, path) = Self.parse(task.taskDescription) else { return }
        Task { @MainActor in self.fileFailed(path, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    nonisolated private static func parse(_ description: String?) -> (String, String)? {
        guard let parts = description?.split(separator: "|", maxSplits: 1), parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}
