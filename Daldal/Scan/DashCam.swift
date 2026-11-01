import AVFoundation
import CoreMotion
import Photos
import UIKit

/// A dash cam on top of Drive Scan: the camera is always recorded into a rolling loop of the last ~20 seconds
/// (four 5-second pieces; older pieces are deleted), and on a sudden jolt or a tap the loop is joined into one video
/// and saved to Photos. Nothing is kept unless something happens.
///
/// Frames come from Drive Scan's AR session (the camera can't be opened twice), on its scan queue.
nonisolated final class DashCam: @unchecked Sendable {
    static let pieceSeconds = 5.0
    static let piecesKept = 4

    private let folder: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInputPixelBufferAdaptor?
    private var pieceStart: TimeInterval = 0
    private var lastFrame: TimeInterval = 0
    private var pieces: [URL] = []
    private var sessionStarted = false
    private let lock = NSLock()

    init() {
        folder = FileManager.default.temporaryDirectory.appending(path: "DashCam", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Adds a camera frame (called on the scan queue for every AR frame; about 30 a second are kept).
    func append(_ pixels: CVPixelBuffer, at time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard time - lastFrame >= 1.0 / 30 else { return }
        lastFrame = time
        if writer == nil || time - pieceStart >= Self.pieceSeconds {
            startPiece(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels), at: time)
        }
        guard let input, input.assetWriterInput.isReadyForMoreMediaData else { return }
        input.append(pixels, withPresentationTime: CMTime(seconds: time - pieceStart, preferredTimescale: 600))
    }

    private func startPiece(width: Int, height: Int, at time: TimeInterval) {
        finishPiece()
        let url = folder.appending(path: "piece-\(Int(time * 1000)).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ])
        video.expectsMediaDataInRealTime = true
        video.transform = CGAffineTransform(rotationAngle: .pi / 2) // The camera's picture is landscape; the phone is upright.
        guard writer.canAdd(video) else { return }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        input = adaptor
        pieceStart = time
        pieces.append(url)
        // Keep only the loop: the oldest pieces go.
        while pieces.count > Self.piecesKept + 1 {
            try? FileManager.default.removeItem(at: pieces.removeFirst())
        }
    }

    private func finishPiece() {
        guard let writer, writer.status == .writing else { return }
        input?.assetWriterInput.markAsFinished()
        writer.finishWriting {}
        self.writer = nil
        input = nil
    }

    /// Joins the last ~20 seconds into one video and saves it to Photos. Returns false if nothing was saved.
    func saveClip() async -> Bool {
        let finished: [URL] = lock.withLock {
            finishPiece()
            return pieces
        }
        // Give the last piece a moment to finish writing.
        try? await Task.sleep(for: .milliseconds(600))
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return false
        }
        var cursor = CMTime.zero
        for url in finished {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            if let transform = try? await source.load(.preferredTransform) { track.preferredTransform = transform }
            cursor = cursor + duration
        }
        guard cursor.seconds > 1 else { return false }
        let output = folder.appending(path: "incident-\(Int(Date.now.timeIntervalSince1970)).mov")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            return false
        }
        do {
            try await export.export(to: output, as: .mov)
        } catch {
            return false
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: output)
            }
            return true
        } catch {
            return false
        }
    }

    func stop() {
        lock.withLock { finishPiece() }
    }
}

/// Watches for a sudden jolt (a crash or very hard braking) with the motion sensors.
@MainActor
final class ImpactDetector {
    /// About 2.5 g of sudden acceleration: far above braking, bumps or potholes.
    static let threshold = 2.5

    private let motion = CMMotionManager()
    private var lastImpact = Date.distantPast

    func start(onImpact: @escaping () -> Void) {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 1.0 / 50
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let a = data?.acceleration else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                // Total acceleration minus gravity's 1 g.
                let jolt = abs(sqrt(a.x * a.x + a.y * a.y + a.z * a.z) - 1)
                if jolt > Self.threshold, Date.now.timeIntervalSince(self.lastImpact) > 30 {
                    self.lastImpact = .now
                    onImpact()
                }
            }
        }
    }

    func stop() {
        motion.stopAccelerometerUpdates()
    }
}
