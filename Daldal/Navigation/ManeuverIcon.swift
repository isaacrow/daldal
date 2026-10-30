import SwiftUI

/// The arrow for a maneuver. Left turns are the right-turn drawing mirrored in physical space,
/// so Arabic's right-to-left layout never flips a "turn right" arrow.
struct ManeuverIcon: View {
    let maneuver: Maneuver
    var size: CGFloat = 48

    var body: some View {
        Icon(glyph, size: size)
            .scaleEffect(x: pointsLeft ? -1 : 1)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
    }

    private var glyph: DaldalIcon {
        switch maneuver.kind {
        case .arrive: return .turnArrive
        case .roundabout: return .turnRoundabout
        case .merge: return .turnMerge
        case .fork: return .turnFork
        case .onRamp, .offRamp: return .turnRamp
        default: break
        }
        return switch maneuver.direction {
        case .uTurn: .turnUTurn
        case .sharpLeft, .sharpRight: .turnSharp
        case .left, .right: .turnRight
        case .slightLeft, .slightRight: .turnSlight
        case .straight, nil: .turnStraight
        }
    }

    private var pointsLeft: Bool {
        switch maneuver.direction {
        case .left, .slightLeft, .sharpLeft: true
        // The U-turn drawing already turns left, as it should where people drive on the right.
        default: false
        }
    }
}

/// One lane arrow for lane guidance. OSRM lane directions are strings like "left" or "slight right".
struct LaneArrow: View {
    let directions: [String]
    /// The direction this route takes from the lane, when the lane is one to use.
    var activeDirection: String? = nil
    let isActive: Bool

    var body: some View {
        ManeuverIcon(maneuver: Maneuver(kind: .turn, direction: direction), size: 26)
            .foregroundStyle(isActive ? Color.primary : Color.secondary.opacity(0.45))
            .frame(width: 34, height: 38)
    }

    private var direction: Maneuver.Direction {
        // A lane can allow several directions: draw the one the route uses, else the most significant.
        let order: [(String, Maneuver.Direction)] = [
            ("uturn", .uTurn), ("sharp left", .sharpLeft), ("sharp right", .sharpRight),
            ("left", .left), ("right", .right), ("slight left", .slightLeft), ("slight right", .slightRight),
        ]
        if let activeDirection, let match = order.first(where: { $0.0 == activeDirection }) { return match.1 }
        if activeDirection == "straight" { return .straight }
        return order.first { directions.contains($0.0) }?.1 ?? .straight
    }
}
