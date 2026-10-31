import CoreLocation
import CoreMotion
import Observation

/// Smooth, instant car motion for the 3D road: GPS gives speed once a second (and lags); the motion sensors
/// give acceleration and turning 30 times a second. Blending them makes the road speed up, slow down and
/// bend the moment the car does. Assumes the phone is mounted facing the road (see MountGuide).
@Observable
final class MotionFusion {
    /// Metres per second.
    private(set) var speed: Double = 0
    /// Radians per second, positive turning left.
    private(set) var turnRate: Double = 0
    /// Metres travelled since start, added up step by step (so the road never jumps when the speed changes).
    private(set) var distance: Double = 0
    /// Core Motion's activity classifier: true while it judges the phone to be in a moving vehicle.
    private(set) var isDriving = false

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let activity = CMMotionActivityManager()
    @ObservationIgnored private var lastGPS: Date?

    func start() {
        if motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive {
            motion.deviceMotionUpdateInterval = 1.0 / 30
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
                guard let data else { return }
                MainActor.assumeIsolated { self?.integrate(data) }
            }
        }
        if CMMotionActivityManager.isActivityAvailable() {
            activity.startActivityUpdates(to: .main) { [weak self] state in
                guard let state else { return }
                MainActor.assumeIsolated { self?.isDriving = state.automotive && !state.stationary }
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        activity.stopActivityUpdates()
    }

    /// A new GPS fix: pulls the estimate towards it (GPS is right on average; the sensors drift).
    func update(gps location: CLLocation?) {
        guard let location, location.speed >= 0, location.timestamp != lastGPS else { return }
        lastGPS = location.timestamp
        speed = speed * 0.3 + location.speed * 0.7
    }

    private func integrate(_ data: CMDeviceMotion) {
        let dt = motion.deviceMotionUpdateInterval
        let g = data.gravity
        let gravityLength = max(sqrt(g.x * g.x + g.y * g.y + g.z * g.z), 0.001)
        // Turning: the gyro's rotation about the vertical (gravity) axis.
        let r = data.rotationRate
        let yaw = -(r.x * g.x + r.y * g.y + r.z * g.z) / gravityLength
        turnRate = turnRate * 0.85 + yaw * 0.15
        // Speeding up or slowing down: acceleration along the camera's view (out of the back, -z).
        let forward = -data.userAcceleration.z * 9.81
        speed = max(0, speed + forward * dt)
        distance += speed * dt
        // With no GPS for a while, let the estimate decay rather than drift away.
        if let lastGPS, Date.now.timeIntervalSince(lastGPS) > 3 { speed *= 0.995 }
    }
}
