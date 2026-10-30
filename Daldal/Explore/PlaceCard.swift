import SwiftUI
import UIKit

/// The sheet shown for a selected place.
struct PlaceCard: View {
    let place: Place
    let onOpenAR: (Place) -> Void
    let onDirections: (Place) -> Void
    let onWalk: (Place) -> Void

    @Environment(LocationService.self) private var location
    @Environment(SavedPlacesStore.self) private var saved
    @Environment(HeritageStore.self) private var heritage
    @State private var copied = false

    private var site: HeritageSite? { place.heritageID.flatMap(heritage.site(id:)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header
                actions
                if let site { HeritageDetails(site: site) }
            }
            .padding(Theme.Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .sensoryFeedback(.success, trigger: copied)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            CategoryBadge(icon: place.category.icon, size: 48)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(place.name)
                    .font(.placeTitle)
                    .lineLimit(2)
                if !place.subtitle.isEmpty {
                    Text(place.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let meters = place.distance(from: location.location) {
                    Text(Measurement(value: meters, unit: UnitLength.meters),
                         format: .measurement(width: .abbreviated, usage: .road))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.s) {
                Button { onDirections(place) } label: {
                    Label { Text("Directions") } icon: { Icon(.navigate, size: 18) }
                }
                .buttonStyle(.glassProminent)

                Button { onWalk(place) } label: {
                    Label { Text("Walk with AR") } icon: { Icon(.walk, size: 18) }
                }
                .buttonStyle(.glass)

                if site != nil {
                    Button { onOpenAR(place) } label: {
                        Label { Text("View in AR") } icon: { Icon(.arView, size: 18) }
                    }
                    .buttonStyle(.glass)
                }

                ShareLink(item: shareURL, subject: Text(place.name)) {
                    Label { Text("Share") } icon: { Icon(.share, size: 18) }
                }
                .buttonStyle(.glass)

                Button {
                    UIPasteboard.general.string = place.coordinate.formattedDegrees
                    copied.toggle()
                } label: {
                    Label { Text("Copy coordinates") } icon: { Icon(.copy, size: 18) }
                }
                .buttonStyle(.glass)

                Menu {
                    Button { saved.set(place, for: .home) } label: {
                        Label { Text("Set as home") } icon: { Icon(.home) }
                    }
                    Button { saved.set(place, for: .work) } label: {
                        Label { Text("Set as work") } icon: { Icon(.work) }
                    }
                } label: {
                    Label { Text("Save") } icon: { Icon(.star, size: 18) }
                }
                .buttonStyle(.glass)
            }
            .font(.subheadline.weight(.semibold))
        }
        .scrollIndicators(.hidden)
    }

    /// An OpenStreetMap link opens anywhere, with or without Daldal installed.
    private var shareURL: URL {
        let lat = place.latitude, lon = place.longitude
        return URL(string: "https://www.openstreetmap.org/?mlat=\(lat)&mlon=\(lon)#map=17/\(lat)/\(lon)")!
    }
}

private struct HeritageDetails: View {
    let site: HeritageSite

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let imageURL = site.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Color.secondary.opacity(0.1)
                    default:
                        Color.secondary.opacity(0.1).overlay(ProgressView())
                    }
                }
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 16))
                .accessibilityHidden(true)
            }

            HStack(spacing: Theme.Spacing.m) {
                if let credit = site.imageCreditURL {
                    Link("Photo: Wikimedia Commons", destination: credit)
                }
                Link("Wikidata", destination: site.wikidataURL)
            }
            .font(.caption)
        }
    }
}
