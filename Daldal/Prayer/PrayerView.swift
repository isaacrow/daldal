import CoreLocation
import SwiftUI

/// The compass heading, for the qibla arrow.
@Observable
final class HeadingProvider: NSObject, CLLocationManagerDelegate {
    private(set) var heading: Double?
    @ObservationIgnored private let manager = CLLocationManager()

    func start() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.delegate = self
        manager.headingFilter = 2
        manager.startUpdatingHeading()
    }

    func stop() { manager.stopUpdatingHeading() }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in self.heading = value }
    }
}

/// Today's prayer times where you are, the next one counting down, and a qibla compass.
struct PrayerView: View {
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss
    @AppStorage("prayer.method") private var method = PrayerTimes.Method.jafari.rawValue
    @State private var compass = HeadingProvider()

    private var coordinate: CLLocationCoordinate2D { location.location?.coordinate ?? Region.defaultCenter }
    private var chosen: PrayerTimes.Method { PrayerTimes.Method(rawValue: method) ?? .jafari }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let today = PrayerTimes(date: timeline.date, coordinate: coordinate, method: chosen)
                let next = today.next(after: timeline.date)
                    ?? PrayerTimes(date: timeline.date.addingTimeInterval(86_400), coordinate: coordinate, method: chosen)
                        .next(after: timeline.date)
                ScrollView {
                    VStack(spacing: Theme.Spacing.l) {
                        if let next {
                            VStack(spacing: 4) {
                                Text(next.0.title).font(.title.weight(.bold))
                                Text(next.1, style: .time).font(.title2.monospacedDigit())
                                Text(next.1, style: .relative).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(Theme.Spacing.l)
                            .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: Theme.cornerRadius))
                        }
                        VStack(spacing: 0) {
                            ForEach(PrayerTimes.Prayer.allCases) { prayer in
                                HStack {
                                    Text(prayer.title).font(.body.weight(next?.0 == prayer ? .bold : .regular))
                                    Spacer()
                                    if let time = today.times[prayer] {
                                        Text(time, style: .time).monospacedDigit()
                                    }
                                }
                                .foregroundStyle(prayer == .sunrise ? .secondary : .primary)
                                .padding(.vertical, 10)
                                if prayer != .isha { Divider() }
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: Theme.cornerRadius))

                        Picker("Method", selection: $method) {
                            Text("Ja'fari").tag(PrayerTimes.Method.jafari.rawValue)
                            Text("Muslim World League").tag(PrayerTimes.Method.mwl.rawValue)
                        }
                        .pickerStyle(.segmented)

                        qiblaCompass
                    }
                    .padding(Theme.Spacing.l)
                }
            }
            .navigationTitle("Prayer times")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Icon(.close, size: 16) }
                        .accessibilityLabel("Close")
                }
            }
        }
        .onAppear { compass.start() }
        .onDisappear { compass.stop() }
    }

    /// An arrow that points to Mecca: the qibla bearing minus where the phone is facing.
    private var qiblaCompass: some View {
        let qibla = PrayerTimes.qibla(from: coordinate)
        let facing = compass.heading ?? 0
        let aligned = compass.heading.map { abs((qibla - $0 + 540).truncatingRemainder(dividingBy: 360) - 180) < 5 } ?? false
        return VStack(spacing: Theme.Spacing.m) {
            Text("Qibla").font(.headline)
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                Capsule()
                    .fill(aligned ? Color.green : Theme.accent)
                    .frame(width: 8, height: 90)
                    .offset(y: -45)
                    .rotationEffect(.degrees(qibla - facing))
                Circle().fill(aligned ? Color.green : Theme.accent).frame(width: 18, height: 18)
            }
            .frame(width: 200, height: 200)
            .animation(.smooth(duration: 0.25), value: facing)
            .environment(\.layoutDirection, .leftToRight)
            Text(compass.heading == nil ? "Qibla is \(Int(qibla.rounded()))° from north."
                 : (aligned ? "You're facing the qibla." : "Turn until the arrow points straight up."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.l)
        .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: Theme.cornerRadius))
        .accessibilityIdentifier("prayer.qibla")
    }
}

/// A small chip under the search bar: the next prayer and its time. Opens the prayer screen.
struct NextPrayerChip: View {
    @Environment(LocationService.self) private var location
    @AppStorage("prayer.method") private var method = PrayerTimes.Method.jafari.rawValue
    let onOpen: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let coordinate = location.location?.coordinate ?? Region.defaultCenter
            let chosen = PrayerTimes.Method(rawValue: method) ?? .jafari
            let next = PrayerTimes(date: timeline.date, coordinate: coordinate, method: chosen).next(after: timeline.date)
                ?? PrayerTimes(date: timeline.date.addingTimeInterval(86_400), coordinate: coordinate, method: chosen)
                    .next(after: timeline.date)
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Icon(.mosque, size: 14)
                    if let next {
                        Text(next.0.title).font(.footnote.weight(.semibold))
                        Text(next.1, style: .time).font(.footnote.monospacedDigit())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("map.prayer")
        }
    }
}
