import SwiftUI

/// Every icon in the app. Each case maps to a template SVG in `Assets.xcassets/Icons`.
/// Never use emoji or SF Symbols for brand UI; add a new SVG and a case here instead.
enum DaldalIcon: String, CaseIterable, Sendable {
    case search, locate, locateFill = "locate-fill", cube, square, layers, compass, close
    case pin, home, work, clock, star, share, copy, chevron, navigate
    case sun, moon, auto
    case fuel, food, cafe, parking, health, shop, road, mosque, city, heritage, arView = "ar"
    case volume, volumeOff = "volume-off", download, trash, route, report, traffic
    case reportJam = "report-jam", reportAccident = "report-accident", reportPolice = "report-police"
    case reportHazard = "report-hazard", reportFlood = "report-flood", reportClosure = "report-closure"
    // Maneuvers. Drawn for right turns; ManeuverIcon mirrors them for left turns.
    case turnStraight = "turn-straight", turnRight = "turn-right", turnSlight = "turn-slight"
    case turnSharp = "turn-sharp", turnUTurn = "turn-uturn", turnMerge = "turn-merge", turnFork = "turn-fork"
    case turnRoundabout = "turn-roundabout", turnRamp = "turn-ramp", turnArrive = "turn-arrive"

    var assetName: String { "icon-\(rawValue)" }

    /// Icons that point in a reading direction and must mirror in Arabic.
    var mirrorsInRightToLeft: Bool { self == .chevron }
}

/// Renders a `DaldalIcon` at a size that follows Dynamic Type.
struct Icon: View {
    private let icon: DaldalIcon
    @ScaledMetric private var size: CGFloat

    init(_ icon: DaldalIcon, size: CGFloat = 20) {
        self.icon = icon
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        Image(icon.assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .flipsForRightToLeftLayoutDirection(icon.mirrorsInRightToLeft)
            .accessibilityHidden(true)
    }
}

#Preview("Icon set") {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 20) {
        ForEach(DaldalIcon.allCases, id: \.self) { icon in
            VStack(spacing: 6) {
                Icon(icon, size: 24)
                Text(icon.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    .padding()
}
