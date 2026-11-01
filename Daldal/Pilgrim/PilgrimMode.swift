import CoreLocation
import SwiftUI

/// The Najaf–Karbala walk (Arbaeen and other ziyarat): where you are along the road by its numbered poles,
/// how far is left, water, toilets and medical points near you, and your position to send to your group.
enum PilgrimRoute {
    /// The walking route from the Imam Ali shrine to the Imam Husayn shrine (OpenStreetMap, via Valhalla).
    static let path: [CLLocationCoordinate2D] = {
        guard let url = Bundle.main.url(forResource: "pilgrim-najaf-karbala", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let points = json["path"] as? [[Double]] else { return [] }
        return points.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
    }()

    static let karbala = CLLocationCoordinate2D(latitude: 32.6164, longitude: 44.0324)

    /// The poles stand about every 50 m along the road out of Najaf, numbered 1 to 1452 towards Karbala.
    static let poleSpacing = 50.0
    static let poleCount = 1452
    /// Distance from the Najaf shrine to pole 1 (the city streets before the road).
    static let firstPoleAt = 5_000.0

    static var length: Double { RouteMath.length(path) }

    struct Progress {
        let walked: Double
        let left: Double
        let pole: Int
        /// Hours left at a steady walking pace of 4.5 km/h.
        var hoursLeft: Double { left / 4_500 }
    }

    /// Where someone is along the walk, or nil when they're more than 1.5 km from the road.
    static func progress(at coordinate: CLLocationCoordinate2D) -> Progress? {
        guard let walked = RouteMath.distanceAlong(path, to: coordinate, maxOffset: 1_500) else { return nil }
        let pole = Int(((walked - firstPoleAt) / poleSpacing).rounded()) + 1
        return Progress(walked: walked, left: max(length - walked, 0), pole: min(max(pole, 1), poleCount))
    }

    /// The next Arbaeen (20 Safar) and Ashura (10 Muharram) by the Umm al-Qura calendar. Iraq follows the moon
    /// sighting, so the real day can differ by one.
    static func nextDays(after now: Date) -> [(LocalizedStringResource, Date)] {
        let hijri = Calendar(identifier: .islamicUmmAlQura)
        let year = hijri.component(.year, from: now)
        func next(month: Int, day: Int) -> Date? {
            for y in [year, year + 1] {
                if let date = hijri.date(from: DateComponents(year: y, month: month, day: day)), date >= now.addingTimeInterval(-86_400) {
                    return date
                }
            }
            return nil
        }
        return [("Arbaeen", next(month: 2, day: 20)), ("Ashura", next(month: 1, day: 10))]
            .compactMap { title, date in date.map { (title, $0) } }
            .sorted { $0.1 < $1.1 }
    }
}

struct PilgrimView: View {
    /// Shows the nearest places of a kind on the map (water, toilets, medical, mosques).
    let onFind: (NearbyCategory) -> Void
    /// Walk (with AR guidance) to the Imam Husayn shrine.
    let onWalkToKarbala: () -> Void
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.l) {
                    progressCard
                    services
                    groupCard
                    days
                }
                .padding(Theme.Spacing.l)
            }
            .navigationTitle("Pilgrim walk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Icon(.close, size: 16) }
                        .accessibilityLabel("Close")
                }
            }
        }
    }

    @ViewBuilder private var progressCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Najaf to Karbala").font(.headline)
            if let here = location.location?.coordinate, let progress = PilgrimRoute.progress(at: here) {
                HStack(alignment: .firstTextBaseline) {
                    Text("About pole \(progress.pole)").font(.title.weight(.bold).monospacedDigit())
                    Spacer()
                    Text("of \(PilgrimRoute.poleCount)").foregroundStyle(.secondary)
                }
                ProgressView(value: progress.walked, total: max(PilgrimRoute.length, 1)).tint(Theme.accent)
                Text("\(Measurement(value: progress.left / 1000, unit: UnitLength.kilometers).formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1))))) to the shrine of Imam Husayn, about \(Int(progress.hoursLeft.rounded())) h walking.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("You're not on the Najaf–Karbala road. The walk starts at the shrine of Imam Ali in Najaf.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button(action: onWalkToKarbala) {
                Label { Text("Walk to the shrine of Imam Husayn") } icon: { Icon(.walk, size: 18) }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("pilgrim.walk")
        }
        .padding(Theme.Spacing.l)
        .background(Theme.accent.opacity(0.1), in: .rect(cornerRadius: Theme.cornerRadius))
        .accessibilityIdentifier("pilgrim.progress")
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Near you").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.s), count: 2), spacing: Theme.Spacing.s) {
                ForEach([NearbyCategory.water, .toilets, .hospital, .mosque]) { category in
                    Button { onFind(category) } label: {
                        Label { Text(category.title) } icon: { Icon(category.icon, size: 18) }
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    @ViewBuilder private var groupCard: some View {
        if let here = location.location?.coordinate {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Your group").font(.headline)
                Text("Send your position so your group can find you, even in the crowd.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ShareLink(item: LocationLink.shareURL(for: here, name: String(localized: "I'm here on the pilgrim walk"))) {
                    Label { Text("Send my location") } icon: { Icon(.share, size: 18) }
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.glass)
            }
            .padding(Theme.Spacing.l)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: Theme.cornerRadius))
        }
    }

    private var days: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(PilgrimRoute.nextDays(after: .now), id: \.1) { title, date in
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(date, format: .dateTime.day().month(.wide).year())
                    Text(date, style: .relative).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            Text("Dates by the Umm al-Qura calendar; in Iraq they follow the moon sighting and may differ by a day.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.l)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: Theme.cornerRadius))
    }
}

/// A chip under the search bar that opens the pilgrim walk.
struct PilgrimChip: View {
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Icon(.walk, size: 14)
                Text("Pilgrim walk").font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .capsule)
        .accessibilityIdentifier("map.pilgrim")
    }
}
