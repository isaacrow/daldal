import CoreMotion
import Observation
import SwiftUI

/// Helps the driver set the phone up so the camera sees the road: level, looking straight ahead, slightly down.
/// Reads gravity from the motion sensors (works for portrait and landscape mounts).
@Observable
final class MountGuide {
    enum Advice: Equatable {
        case good
        case tiltBack, tiltForward // the top of the phone
        case level // turn it like a steering wheel until the bubble centres
        case flat // lying down: not mounted

        var text: LocalizedStringKey {
            switch self {
            case .good: "Mount is good: the camera sees the road."
            case .tiltBack: "Tilt the top of the phone back, towards you."
            case .tiltForward: "Tilt the top of the phone forward, towards the road."
            case .level: "Turn the phone like a steering wheel until the bubble is centred."
            case .flat: "Mount the phone upright in a holder, high in the middle of the windscreen."
            }
        }
    }

    private(set) var advice: Advice = .flat
    /// How far the camera points down at the road (degrees; 0 is the horizon).
    private(set) var downTilt: Double = 0
    /// Sideways lean (degrees; 0 is level).
    private(set) var roll: Double = 0
    /// True once the mount has been good for a couple of seconds: the guide can step aside.
    private(set) var settled = false

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var goodSince: Date?

    /// The camera should look at the road a little below the horizon.
    static let tiltRange = -4.0...14.0
    static let maxRoll = 6.0

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            MainActor.assumeIsolated { self?.update(gravity) }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    private func update(_ g: CMAcceleration) {
        // Device axes: x right, y to the top edge, z out of the screen. The camera looks along -z.
        downTilt = asin(max(-1, min(1, -g.z))) * 180 / .pi
        // Roll against whichever edge points up (portrait or landscape holder).
        roll = abs(g.y) >= abs(g.x)
            ? atan2(g.x, abs(g.y)) * 180 / .pi * (g.y < 0 ? 1 : -1)
            : atan2(g.y, abs(g.x)) * 180 / .pi * (g.x < 0 ? -1 : 1)
        let next: Advice
        if abs(g.z) > 0.85 {
            next = .flat
        } else if downTilt > Self.tiltRange.upperBound {
            next = .tiltBack
        } else if downTilt < Self.tiltRange.lowerBound {
            next = .tiltForward
        } else if abs(roll) > Self.maxRoll {
            next = .level
        } else {
            next = .good
        }
        if next != advice { advice = next }
        if next == .good {
            goodSince = goodSince ?? .now
            if !settled, let goodSince, Date.now.timeIntervalSince(goodSince) > 2 { settled = true }
        } else {
            goodSince = nil
            if settled, next != .good { settled = false }
        }
    }
}

/// A spirit level and one line of advice, shown until the phone is mounted well.
struct MountGuideView: View {
    let guide: MountGuide

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ZStack {
                Circle().stroke(.white.opacity(0.5), lineWidth: 1.5)
                Circle().stroke(.white.opacity(0.25), lineWidth: 1).padding(9)
                // The bubble: drifts with tilt (up/down) and roll (sideways), centred when the mount is right.
                Circle()
                    .fill(guide.advice == .good ? Color.green : Color.orange)
                    .frame(width: 12, height: 12)
                    .offset(x: CGFloat(max(-1, min(1, guide.roll / 20))) * 16,
                            y: CGFloat(max(-1, min(1, (guide.downTilt - 5) / 25))) * 16)
                    .animation(.smooth(duration: 0.2), value: guide.roll)
                    .animation(.smooth(duration: 0.2), value: guide.downTilt)
            }
            .frame(width: 46, height: 46)
            Text(guide.advice.text)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.m)
        .glassEffect(.regular.tint(guide.advice == .good ? .green.opacity(0.25) : .orange.opacity(0.2)),
                     in: .rect(cornerRadius: Theme.cornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scan.mountGuide")
    }
}
