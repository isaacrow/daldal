import ARKit
import AVFoundation
import CoreImage
import CoreML
import Observation
import UIKit
import Vision

/// Something the camera sees on the road, placed in metres relative to the phone.
nonisolated struct ScannedObject: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case car, truck, bus, motorbike, bicycle, person, trafficLight, stopSign, animal, train

        /// Typical real height in metres, used to turn on-screen size into distance.
        var realHeight: Double {
            switch self {
            case .car: 1.5
            case .truck: 3.2
            case .bus: 3.1
            case .motorbike: 1.3
            case .bicycle: 1.1
            case .person: 1.7
            case .trafficLight: 0.9 // the lamp housing
            case .stopSign: 0.75
            case .animal: 1.2 // sheep and dogs are lower, cows and horses taller: a middle value
            case .train: 3.8
            }
        }

        /// The model's COCO class names.
        init?(label: String) {
            switch label {
            case "car": self = .car
            case "truck": self = .truck
            case "bus": self = .bus
            case "motorbike", "motorcycle": self = .motorbike
            case "bicycle": self = .bicycle
            case "person": self = .person
            case "traffic light": self = .trafficLight
            case "stop sign": self = .stopSign
            // Animals on the road are a real hazard on Iraqi highways and rural roads.
            case "dog", "horse", "sheep", "cow", "cat": self = .animal
            case "train": self = .train
            default: return nil
            }
        }
    }

    enum Light: Sendable { case red, yellow, green }

    let id: Int
    var kind: Kind
    /// Metres ahead of the phone.
    var distance: Double
    /// Metres to the right (+) or left (-) of straight ahead.
    var lateral: Double
    /// Where it is in the camera picture: normalized, top-left origin, portrait.
    var box: CGRect
    var confidence: Float
    var light: Light?
    /// Measured by LiDAR (close range) instead of estimated from size.
    var measuredDepth: Bool
    /// Metres per second the gap is shrinking (positive = getting closer).
    var closingSpeed: Double
}

/// The Drive Scan: on-device detection of vehicles, people, traffic lights and stop signs,
/// with distances, traffic-light colour, and a forward-collision warning.
@Observable
final class DriveScanModel: NSObject {
    enum Status: Equatable { case starting, running, unsupported, cameraDenied, modelMissing }

    let session = ARSession()
    private(set) var status: Status = .starting
    private(set) var objects: [ScannedObject] = []
    /// True for a few seconds after a collision warning fires.
    private(set) var warning = false
    private(set) var hasLiDAR = false

    @ObservationIgnored private let queue = DispatchQueue(label: "app.daldal.scan", qos: .userInitiated)
    /// Set once before the session starts, then only read on the scan queue.
    @ObservationIgnored nonisolated(unsafe) private var detector: ScanDetector?
    @ObservationIgnored private let voice: VoiceGuide
    @ObservationIgnored private var lastWarning = Date.distantPast

    init(voice: VoiceGuide) {
        self.voice = voice
        super.init()
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { status = .unsupported; return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .denied { status = .cameraDenied; return }
        guard let detector = ScanDetector() else { status = .modelMissing; return }
        self.detector = detector

        let config = ARWorldTrackingConfiguration()
        // LiDAR depth when the phone has it: exact distances for anything within ~5 m (parking, queues).
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
            hasLiDAR = true
        }
        session.delegateQueue = queue
        session.delegate = self
        session.run(config)
        status = .running
    }

    func stop() {
        session.pause()
        session.delegate = nil
    }

    fileprivate func apply(_ result: ScanDetector.Result) {
        objects = result.objects
        guard result.collisionRisk, Date.now.timeIntervalSince(lastWarning) > 4 else { return }
        lastWarning = .now
        warning = true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        voice.announce(AppLanguage.code == "ar" ? "انتبه، سيارة قريبة أمامك" : "Watch out, car close ahead", interrupt: true)
        Task {
            try? await Task.sleep(for: .seconds(3))
            warning = false
        }
    }
}

extension DriveScanModel: ARSessionDelegate {
    /// Runs on the scan queue. Frames are processed synchronously and never kept, as ARKit requires.
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let detector, detector.shouldProcess(frame.timestamp), let result = detector.process(frame) else { return }
        Task { @MainActor in self.apply(result) }
    }
}

/// Everything that touches camera frames. Lives on the scan queue only.
nonisolated final class ScanDetector: @unchecked Sendable {
    struct Result: Sendable {
        let objects: [ScannedObject]
        let collisionRisk: Bool
    }

    private let request: VNCoreMLRequest
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastProcessed: TimeInterval = 0
    private var tracked: [ScannedObject] = []
    private var lastTime: TimeInterval = 0
    private var nextID = 1

    init?() {
        guard let url = Bundle.main.url(forResource: "YOLOv3Int8LUT", withExtension: "mlmodelc"),
              let mlModel = try? MLModel(contentsOf: url, configuration: {
                  let config = MLModelConfiguration()
                  config.computeUnits = .all // Neural Engine when available
                  return config
              }()),
              let visionModel = try? VNCoreMLModel(for: mlModel)
        else { return nil }
        request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
    }

    /// Runs only the model on a still picture: what it sees and how sure it is. Used by tests with real photos.
    func labels(in image: CGImage) -> [(label: String, confidence: Float)] {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let observations = request.results as? [VNRecognizedObjectObservation] else { return [] }
        return observations.compactMap { o in o.labels.first.map { ($0.identifier, $0.confidence) } }
    }

    /// About 8 detections a second; 3 when the phone is hot.
    func shouldProcess(_ timestamp: TimeInterval) -> Bool {
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let interval = hot ? 0.33 : 0.12
        guard timestamp - lastProcessed >= interval else { return false }
        lastProcessed = timestamp
        return true
    }

    func process(_ frame: ARFrame) -> Result? {
        let pixels = frame.capturedImage
        // Portrait phone, back camera: the sensor image is landscape, rotated right for display.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right)
        guard (try? handler.perform([request])) != nil,
              let observations = request.results as? [VNRecognizedObjectObservation] else { return nil }

        let intrinsics = frame.camera.intrinsics
        let fx = Double(intrinsics[0][0]), fy = Double(intrinsics[1][1])
        let cy = Double(intrinsics[2][1])
        let width = Double(frame.camera.imageResolution.width)   // landscape
        let height = Double(frame.camera.imageResolution.height)
        let depth = frame.sceneDepth?.depthMap
        let oriented = CIImage(cvPixelBuffer: pixels).oriented(.right)

        var found: [ScannedObject] = []
        for observation in observations {
            guard let top = observation.labels.first, top.confidence >= 0.4,
                  let kind = ScannedObject.Kind(label: top.identifier) else { continue }
            let b = observation.boundingBox // portrait, normalized, bottom-left origin
            // Portrait height runs along the sensor's long side (landscape width, focal fx).
            let heightPixels = Double(b.height) * width
            guard heightPixels > 4 else { continue }
            var distance = kind.realHeight * fx / heightPixels
            var measured = false

            // Portrait x maps to the sensor's y axis, flipped.
            let sensorY = (1 - Double(b.midX)) * height
            let sensorX = (1 - Double(b.midY)) * width
            if let depth, let metres = Self.depth(at: CGPoint(x: sensorX / width, y: sensorY / height), in: depth), metres < 4.5 {
                distance = metres // LiDAR is exact up close; beyond ~5 m it can't see.
                measured = true
            }
            let lateral = -distance * (sensorY - cy) / fy

            var light: ScannedObject.Light?
            if kind == .trafficLight { light = Self.lightColor(in: oriented, box: b, context: ciContext) }

            let topLeft = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            found.append(ScannedObject(id: 0, kind: kind, distance: distance, lateral: lateral, box: topLeft,
                                       confidence: top.confidence, light: light, measuredDepth: measured, closingSpeed: 0))
        }
        return track(found, at: frame.timestamp)
    }

    /// Keeps identities across frames (so the 3D view doesn't flicker) and measures how fast gaps close.
    private func track(_ found: [ScannedObject], at time: TimeInterval) -> Result {
        let dt = max(time - lastTime, 0.05)
        lastTime = time
        var previous = tracked
        var result: [ScannedObject] = []
        for var object in found {
            if let index = previous.indices.min(by: {
                Self.gap(previous[$0], object) < Self.gap(previous[$1], object)
            }), previous[index].kind == object.kind, Self.gap(previous[index], object) < 5 {
                let old = previous.remove(at: index)
                object = ScannedObject(
                    id: old.id, kind: object.kind,
                    distance: 0.5 * old.distance + 0.5 * object.distance,
                    lateral: 0.5 * old.lateral + 0.5 * object.lateral,
                    box: object.box, confidence: object.confidence, light: object.light ?? old.light,
                    measuredDepth: object.measuredDepth,
                    closingSpeed: 0.7 * old.closingSpeed + 0.3 * ((old.distance - object.distance) / dt)
                )
            } else {
                object = ScannedObject(id: nextID, kind: object.kind, distance: object.distance, lateral: object.lateral,
                                       box: object.box, confidence: object.confidence, light: object.light,
                                       measuredDepth: object.measuredDepth, closingSpeed: 0)
                nextID += 1
            }
            result.append(object)
        }
        tracked = result

        // Forward collision: a vehicle in our lane we'd reach in under ~2.2 s at the current closing speed.
        let risk = result.contains { o in
            [.car, .truck, .bus, .motorbike].contains(o.kind) && abs(o.lateral) < 1.6 && o.distance < 30
                && o.closingSpeed > 1.5 && o.distance / o.closingSpeed < 2.2
        }
        return Result(objects: result, collisionRisk: risk)
    }

    private static func gap(_ a: ScannedObject, _ b: ScannedObject) -> Double {
        hypot(a.distance - b.distance, (a.lateral - b.lateral) * 2)
    }

    /// Median LiDAR depth in a small window around a normalized point of the (landscape) depth map.
    private static func depth(at point: CGPoint, in map: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let cx = Int(point.x * Double(w)), cy = Int(point.y * Double(h))
        var values: [Float] = []
        for y in max(0, cy - 2)...min(h - 1, cy + 2) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in max(0, cx - 2)...min(w - 1, cx + 2) where row[x].isFinite && row[x] > 0 {
                values.append(row[x])
            }
        }
        guard !values.isEmpty else { return nil }
        return Double(values.sorted()[values.count / 2])
    }

    /// Which lamp is lit: compares the brightness of the top, middle and bottom thirds, then checks the hue.
    private static func lightColor(in image: CIImage, box: CGRect, context: CIContext) -> ScannedObject.Light? {
        let extent = image.extent
        let rect = CGRect(x: extent.minX + box.minX * extent.width, y: extent.minY + box.minY * extent.height,
                          width: box.width * extent.width, height: box.height * extent.height)
        guard rect.width > 3, rect.height > 9 else { return nil }
        var thirds: [(lum: Double, r: Double, g: Double)] = []
        for i in 0..<3 { // bottom, middle, top (CIImage's origin is bottom-left)
            let part = CGRect(x: rect.minX, y: rect.minY + rect.height * Double(i) / 3, width: rect.width, height: rect.height / 3)
            let average = image.cropped(to: part).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: part)])
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            let r = Double(pixel[0]), g = Double(pixel[1]), b = Double(pixel[2])
            thirds.append((0.299 * r + 0.587 * g + 0.114 * b, r, g))
        }
        guard let lit = thirds.indices.max(by: { thirds[$0].lum < thirds[$1].lum }),
              thirds[lit].lum > 60 else { return nil }
        let (_, r, g) = thirds[lit]
        // Hue first; the lamp's position settles ambiguous colours.
        if r > g * 1.35 { return .red }
        if g > r * 1.1 { return .green }
        return lit == 2 ? .red : lit == 0 ? .green : .yellow
    }
}
