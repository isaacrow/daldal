import ARKit
import SwiftUI
import Vision

/// Lets visitors handle AR models with their hand in front of the camera, like RealityKit on Vision Pro:
/// pinch (thumb and index finger together) to grab, move sideways to turn, up and down to resize.
///
/// iPhone has no hand-tracking API, so Vision finds the hand in the camera picture (about 10 times a second).
final class HandControl: NSObject, ARSessionDelegate {
    struct Hand: Sendable {
        /// Pinch point in screen terms: 0...1 from the left and from the top (portrait).
        let point: CGPoint
        let pinched: Bool
    }

    /// Called on the main actor with each hand reading (nil when no hand is seen).
    var onHand: (Hand?) -> Void = { _ in }
    /// Called while pinched, with how far the pinch moved since the last reading (screen fractions).
    var onDrag: (CGVector) -> Void = { _ in }

    private let queue = DispatchQueue(label: "app.daldal.hands", qos: .userInitiated)
    private nonisolated let detector = HandDetector()
    private var lastPinch: CGPoint?

    func attach(to session: ARSession) {
        session.delegateQueue = queue
        session.delegate = self
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard detector.shouldProcess(frame.timestamp) else { return }
        let hand = detector.hand(in: frame.capturedImage)
        Task { @MainActor in self.handle(hand) }
    }

    private func handle(_ hand: Hand?) {
        onHand(hand)
        guard let hand, hand.pinched else {
            lastPinch = nil
            return
        }
        if let lastPinch {
            onDrag(CGVector(dx: hand.point.x - lastPinch.x, dy: hand.point.y - lastPinch.y))
        }
        lastPinch = hand.point
    }
}

/// Vision hand pose on camera frames. Used only from the hands queue.
nonisolated final class HandDetector: @unchecked Sendable {
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()
    private var last: TimeInterval = 0

    func shouldProcess(_ timestamp: TimeInterval) -> Bool {
        guard timestamp - last >= 0.1 else { return false }
        last = timestamp
        return true
    }

    func hand(in pixels: CVPixelBuffer) -> HandControl.Hand? {
        // The camera's picture is landscape; .right turns it upright for a phone held in portrait.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let thumb = try? observation.recognizedPoint(.thumbTip),
              let index = try? observation.recognizedPoint(.indexTip),
              let wrist = try? observation.recognizedPoint(.wrist),
              thumb.confidence > 0.4, index.confidence > 0.4 else { return nil }
        // Pinched when fingertips are close compared with the hand's size (so it works near and far).
        let gap = hypot(thumb.location.x - index.location.x, thumb.location.y - index.location.y)
        let size = max(hypot(index.location.x - wrist.location.x, index.location.y - wrist.location.y), 0.01)
        let mid = CGPoint(x: (thumb.location.x + index.location.x) / 2, y: 1 - (thumb.location.y + index.location.y) / 2)
        return HandControl.Hand(point: mid, pinched: gap / size < 0.28)
    }
}

/// A dot that follows the visitor's fingers over the camera view; green while they pinch.
struct HandIndicator: View {
    let hand: HandControl.Hand?

    var body: some View {
        GeometryReader { geometry in
            if let hand {
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().fill(hand.pinched ? Color.green.opacity(0.7) : Color.white.opacity(0.25)))
                    .frame(width: hand.pinched ? 30 : 22, height: hand.pinched ? 30 : 22)
                    .position(x: hand.point.x * geometry.size.width, y: hand.point.y * geometry.size.height)
                    .animation(.smooth(duration: 0.12), value: hand.point)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Sometimes the camera starts black: the session runs (motion and the floor are tracked) but no picture arrives,
/// usually because the camera was still being released by the previous AR screen. Reopening fixes it, so this does
/// the same automatically: if no camera frame has arrived after a moment, restart the session once or twice.
enum ARCameraWatchdog {
    static func watch(_ session: ARSession, configuration: ARConfiguration, attempts: Int = 2) {
        Task { @MainActor in
            for _ in 0..<attempts {
                try? await Task.sleep(for: .seconds(2.5))
                if session.currentFrame != nil { return }
                session.pause()
                try? await Task.sleep(for: .milliseconds(300))
                session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            }
        }
    }
}
