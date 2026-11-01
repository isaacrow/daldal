import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DaldalWidgets: WidgetBundle {
    var body: some Widget {
        NavigationActivityWidget()
    }
}

/// Turn-by-turn on the lock screen and in the Dynamic Island: the next instruction, how far to it, and the arrival time.
struct NavigationActivityWidget: Widget {
    private static let accent = Color(red: 0.05, green: 0.6, blue: 0.55)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NavigationActivityAttributes.self) { context in
            LockScreenTrip(context: context)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(Self.distance(context.state.distanceToTurn))
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(Self.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.arrival, format: .dateTime.hour().minute())
                            .font(.headline.monospacedDigit())
                        Text(Self.distance(context.state.distanceRemaining)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.instruction)
                        .font(.headline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: context.state.rightToLeft ? .trailing : .leading)
                }
            } compactLeading: {
                Text(Self.distance(context.state.distanceToTurn))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Self.accent)
            } compactTrailing: {
                Text(context.state.arrival, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit())
            } minimal: {
                Text(Self.distance(context.state.distanceToTurn))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(Self.accent)
            }
        }
    }

    static func distance(_ metres: Double) -> String {
        metres < 1000
            ? "\(Int((metres / 10).rounded() * 10)) m"
            : String(format: "%.1f km", locale: Locale(identifier: "en_US_POSIX"), metres / 1000)
    }
}

private struct LockScreenTrip: View {
    let context: ActivityViewContext<NavigationActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(NavigationActivityWidget.distance(context.state.distanceToTurn))
                    .font(.title.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color(red: 0.05, green: 0.6, blue: 0.55))
                Spacer()
                Text(context.state.arrival, format: .dateTime.hour().minute())
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
            Text(context.state.instruction)
                .font(.headline)
                .lineLimit(2)
            HStack {
                Text(context.attributes.destination).lineLimit(1)
                Spacer()
                Text(NavigationActivityWidget.distance(context.state.distanceRemaining)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(16)
        .environment(\.layoutDirection, context.state.rightToLeft ? .rightToLeft : .leftToRight)
    }
}
