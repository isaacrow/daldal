import SwiftUI

/// Your driving record and level. Everything here stays on this phone.
struct StatsView: View {
    @Environment(DriverStats.self) private var stats
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: Theme.Spacing.m), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.l) {
                    levelCard
                    LazyVGrid(columns: columns, spacing: Theme.Spacing.m) {
                        StatTile(icon: .road, title: "Distance driven",
                                 value: Measurement(value: stats.metresDriven, unit: UnitLength.meters)
                                     .formatted(.measurement(width: .abbreviated, usage: .road)))
                        StatTile(icon: .route, title: "Trips", value: stats.trips.formatted())
                        StatTile(icon: .clock, title: "Time driving",
                                 value: Duration.seconds(stats.secondsDriving).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        StatTile(icon: .report, title: "Reports sent", value: stats.reportsSent.formatted())
                        StatTile(icon: .star, title: "Reports confirmed", value: stats.confirmations.formatted())
                        StatTile(icon: .heritage, title: "Places explored", value: stats.placesExplored.count.formatted())
                    }
                    Text("Your record stays on this iPhone. Reports and confirmations help other drivers see what's on the road.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    AppCredit()
                        .padding(.top, Theme.Spacing.xl)
                }
                .padding(Theme.Spacing.l)
            }
            .navigationTitle("My driving")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Icon(.close, size: 16) }
                        .accessibilityLabel("Close")
                }
            }
        }
    }

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.m) {
                CategoryBadge(icon: .profile, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DriverStats.levels[stats.level].name)
                        .font(.title2.weight(.bold))
                    Text("\(stats.points) points")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            ProgressView(value: stats.progressToNext)
                .tint(Theme.accent)
            if stats.level + 1 < DriverStats.levels.count {
                Text("Next: \(Text(DriverStats.levels[stats.level + 1].name))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.l)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

private struct StatTile: View {
    let icon: DaldalIcon
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Icon(icon, size: 20).foregroundStyle(Theme.accent)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

/// Who made Daldal. The name is shown in both scripts whatever the app's language.
struct AppCredit: View {
    var body: some View {
        VStack(spacing: 6) {
            Image("LaunchLogo")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(height: 44)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            Text("Designed and developed by")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "اسحاق فالح علي آل محمد")
                .font(.subheadline.weight(.semibold))
            Text(verbatim: "Isaac Faleh Ali Almohammed")
                .font(.subheadline.weight(.semibold))
                .environment(\.layoutDirection, .leftToRight)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("app.credit")
    }
}
