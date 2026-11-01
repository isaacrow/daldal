import ActivityKit
import Foundation

/// The trip on the lock screen and in the Dynamic Island while navigating. Shared by the app (which starts and
/// updates it) and the widget extension (which draws it).
nonisolated struct NavigationActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        /// The next instruction, as spoken ("لف يمين إلى شارع الرشيد").
        var instruction: String
        /// Metres to that turn.
        var distanceToTurn: Double
        /// Metres left to the destination.
        var distanceRemaining: Double
        var arrival: Date
        /// True for right-to-left layout (Arabic).
        var rightToLeft: Bool
    }

    var destination: String
}
