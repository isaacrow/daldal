import SwiftUI

/// Download, update or remove each city's offline map, and check traffic sharing and the voice.
struct OfflineMapsView: View {
    @Environment(CityMapsStore.self) private var cities
    @Environment(NavigationModel.self) private var nav
    @Environment(LiveStore.self) private var live
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete: CityCatalog.City?
    @AppStorage("traffic.share") private var shareTraffic = true

    private var languageCode: String { AppLanguage.code }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    citiesContent
                } header: {
                    Text("City maps")
                } footer: {
                    Text("A downloaded city's map, search and directions work without internet. Trips between cities use the internet when there is signal.")
                }

                if live.isAvailable {
                    Section {
                        Toggle(isOn: $shareTraffic) {
                            HStack(spacing: Theme.Spacing.m) {
                                CategoryBadge(icon: .traffic, size: 36)
                                Text("Help with live traffic").font(.rowTitle)
                            }
                        }
                    } footer: {
                        Text("While you navigate, your speed is shared anonymously: a new random code each trip, never the first or last 300 m, and only averages from several drivers are kept.")
                    }
                }

                Section {
                    HStack(spacing: Theme.Spacing.m) {
                        CategoryBadge(icon: .volume, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice guidance").font(.rowTitle)
                            Text(nav.voice.hasHighQualityVoice ? "Using a high-quality voice" : "Using the basic voice")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if !nav.voice.hasHighQualityVoice {
                        Text("For clearer directions, download an Enhanced Arabic voice in Settings › Accessibility › Spoken Content › Voices › Arabic.")
                    }
                }
            }
            .navigationTitle("Offline maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Icon(.close, size: 16) }
                        .accessibilityLabel("Close")
                }
            }
            // Every time the screen opens: new cities and weekly updates appear without restarting the app.
            .task { await cities.loadCatalog() }
            .refreshable { await cities.loadCatalog() }
            .confirmationDialog(
                Text("Remove \(confirmingDelete?.name(languageCode: languageCode) ?? "") from this iPhone?"),
                isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let city = confirmingDelete { cities.delete(city.id) }
                }
            }
        }
    }

    @ViewBuilder private var citiesContent: some View {
        if let catalog = cities.catalog {
            ForEach(sorted(catalog.cities)) { city in
                CityRow(city: city, state: cities.state(of: city.id), hasUpdate: cities.hasUpdate(city.id),
                        isHere: isHere(city), languageCode: languageCode,
                        onDownload: { Task { await cities.download(city) } },
                        onRemove: { confirmingDelete = city })
            }
        } else if cities.isLoadingCatalog {
            HStack { Spacer(); ProgressView(); Spacer() }
        } else if let error = cities.catalogError {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text(error).foregroundStyle(.secondary)
                Button("Try again") { Task { await cities.loadCatalog() } }
                    .buttonStyle(.glass)
            }
        }
    }

    /// The city you're in first, then downloaded ones, then the rest by size of city (catalog order).
    private func sorted(_ list: [CityCatalog.City]) -> [CityCatalog.City] {
        let here = list.filter(isHere)
        let downloaded = list.filter { !isHere($0) && cities.installed[$0.id] != nil }
        let rest = list.filter { !isHere($0) && cities.installed[$0.id] == nil }
        return here + downloaded + rest
    }

    private func isHere(_ city: CityCatalog.City) -> Bool {
        guard let here = location.location?.coordinate, city.bbox.count == 4 else { return false }
        return (city.bbox[0]...city.bbox[2]).contains(here.longitude) && (city.bbox[1]...city.bbox[3]).contains(here.latitude)
    }
}

private struct CityRow: View {
    let city: CityCatalog.City
    let state: CityMapsStore.CityState
    let hasUpdate: Bool
    let isHere: Bool
    let languageCode: String
    let onDownload: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.m) {
                CategoryBadge(icon: .city, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(city.name(languageCode: languageCode)).font(.rowTitle)
                    Text(subtitle)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(isHere && state == .available ? Theme.accent : .secondary)
                }
                Spacer(minLength: 0)
                action
            }
            switch state {
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(max(total, 1)))
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var subtitle: String {
        let size = city.totalBytes.formatted(.byteCount(style: .file))
        switch state {
        case .downloading(let received, let total):
            return "\(received.formatted(.byteCount(style: .file))) / \(total.formatted(.byteCount(style: .file)))"
        case .verifying: return String(localized: "Checking files…")
        case .installed: return hasUpdate ? String(localized: "Update available · \(size)") : String(localized: "Downloaded · \(size)")
        case .failed: return size
        case .available: return isHere ? String(localized: "You're here · \(size)") : size
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .available, .failed:
            Button(action: onDownload) { Icon(.download, size: 18) }
                .buttonStyle(.glassProminent)
                .accessibilityLabel("Download")
        case .downloading, .verifying:
            ProgressView()
        case .installed:
            HStack(spacing: Theme.Spacing.s) {
                if hasUpdate {
                    Button(action: onDownload) { Icon(.download, size: 16) }
                        .buttonStyle(.glassProminent)
                        .accessibilityLabel("Update")
                }
                Button(role: .destructive, action: onRemove) { Icon(.trash, size: 16) }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Remove")
            }
        }
    }
}
