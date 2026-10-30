import CoreLocation
import SwiftUI

/// The best places to visit in the city you're in (or looking at), with photos.
struct DiscoverView: View {
    let near: CLLocationCoordinate2D?
    let onSelect: (GuidePlace) -> Void

    @Environment(CityGuideStore.self) private var guide
    @Environment(\.dismiss) private var dismiss

    private var languageCode: String { AppLanguage.code }
    private var city: GuideCity? { near.flatMap(guide.city(near:)) ?? guide.cities.first }

    var body: some View {
        NavigationStack {
            List {
                if let city {
                    Section {
                        ForEach(city.places) { place in
                            Button { onSelect(place) } label: { DiscoverRow(place: place, languageCode: languageCode) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Places to visit in \(city.name(languageCode: languageCode))")
                    } footer: {
                        Text("Places from Wikidata; descriptions from Wikipedia (CC BY-SA 4.0).")
                    }
                }
            }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Icon(.close, size: 16) }
                        .accessibilityLabel("Close")
                }
            }
        }
    }
}

private struct DiscoverRow: View {
    let place: GuidePlace
    let languageCode: String

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Group {
                if let url = place.imageURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Theme.accent.opacity(0.12).overlay(Icon(.heritage, size: 22).foregroundStyle(Theme.accent))
                        }
                    }
                } else {
                    Theme.accent.opacity(0.12).overlay(Icon(.heritage, size: 22).foregroundStyle(Theme.accent))
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(place.name(languageCode: languageCode))
                    .font(.rowTitle)
                    .lineLimit(2)
                if let summary = place.summary(languageCode: languageCode) {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Icon(.chevron, size: 14).foregroundStyle(.tertiary)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
