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
                    PrayerRow()
                    LanguageSwitch()
                    RoughRoadSettings()
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

/// Arabic or English for the whole app (menus, voice, place names). iOS applies an app's language when it starts,
/// so switching asks the user to reopen Daldal.
struct LanguageSwitch: View {
    @State private var chosen = AppLanguage.code
    @State private var askReopen = false
    @AppStorage(ManeuverPhraser.iraqiKey) private var iraqi = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Language").font(.headline)
            Picker("Language", selection: $chosen) {
                Text(verbatim: "العربية").tag("ar")
                Text(verbatim: "English").tag("en")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.language")
            if chosen == "ar" {
                Toggle("Spoken directions in Iraqi dialect", isOn: $iraqi)
                    .font(.subheadline)
                    .accessibilityIdentifier("settings.iraqi")
            }
        }
        .padding(Theme.Spacing.l)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: Theme.cornerRadius))
        .onChange(of: chosen) { _, code in
            guard code != AppLanguage.code else { return }
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
            askReopen = true
        }
        .alert(chosen == "ar" ? "أغلق دلدل وافتحه مجدداً" : "Close Daldal and open it again", isPresented: $askReopen) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: chosen == "ar" ? "سيظهر التطبيق بالعربية عند فتحه مجدداً."
                                          : "The app will be in English the next time it opens.")
        }
    }
}

/// The automatic pothole map: on/off, how many rough spots were found, and clearing them.
struct RoughRoadSettings: View {
    @Environment(RoughRoadStore.self) private var roughRoads
    @AppStorage("potholes.detect") private var detect = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Toggle("Find potholes while driving", isOn: $detect)
                .font(.headline)
                .accessibilityIdentifier("settings.potholes")
            Text("Your phone feels sharp jolts while you navigate and marks rough spots on your map. Spots felt twice are shared as pothole reports when live reports are on.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !roughRoads.spots.isEmpty {
                HStack {
                    Text("\(roughRoads.spots.count) rough spots on your map").font(.subheadline)
                    Spacer()
                    Button("Clear", role: .destructive) { roughRoads.clear() }.font(.subheadline)
                }
            }
        }
        .padding(Theme.Spacing.l)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: Theme.cornerRadius))
    }
}

/// Prayer times and qibla, opened from the profile.
struct PrayerRow: View {
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack {
                Icon(.mosque, size: 20).foregroundStyle(Theme.accent)
                Text("Prayer times and qibla").font(.headline)
                Spacer()
                Icon(.chevron, size: 14).foregroundStyle(.secondary)
            }
            .padding(Theme.Spacing.l)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) { PrayerView() }
        .accessibilityIdentifier("profile.prayer")
    }
}
