import SwiftUI
import UIKit

/// The sheet shown for a selected place.
struct PlaceCard: View {
    let place: Place
    let onOpenAR: (Place) -> Void
    let onDirections: (Place) -> Void
    let onWalk: (Place) -> Void
    let onHistory: (Place) -> Void

    @Environment(LocationService.self) private var location
    @Environment(SavedPlacesStore.self) private var saved
    @Environment(HeritageStore.self) private var heritage
    @Environment(CityGuideStore.self) private var guide
    @Environment(NavigationModel.self) private var nav
    @Environment(HistoryStore.self) private var history
    @State private var copied = false

    private var site: HeritageSite? { place.heritageID.flatMap(heritage.site(id:)) }
    private var guidePlace: GuidePlace? { place.guideID.flatMap(guide.place(id:)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header
                actions
                if let guidePlace {
                    GuideDetails(place: guidePlace, voice: nav.voice)
                } else if let site {
                    HeritageDetails(site: site)
                }
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

    /// A fixed grid, not a sideways-scrolling row: nested scroll views inside a draggable sheet could
    /// claim a real finger's tap (it always moves a little) and cancel the button, so taps did nothing on phones.
    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            Button { onDirections(place) } label: {
                Label { Text("Directions") } icon: { Icon(.navigate, size: 18) }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("place.directions")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.s), GridItem(.flexible())], spacing: Theme.Spacing.s) {
                actionButton("Walk with AR", icon: .walk, id: "place.walk") { onWalk(place) }
                if site != nil {
                    actionButton("View in AR", icon: .arView, id: "place.ar") { onOpenAR(place) }
                }
                if site != nil || guidePlace != nil
                    || !history.events(near: place.coordinate, languageCode: AppLanguage.code).isEmpty {
                    actionButton("History in AR", icon: .history, id: "place.history") { onHistory(place) }
                }
                ShareLink(item: shareURL, subject: Text(place.name)) {
                    Label { Text("Share") } icon: { Icon(.share, size: 18) }
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glass)
                actionButton("Copy coordinates", icon: .copy, id: "place.copy") {
                    UIPasteboard.general.string = place.coordinate.formattedDegrees
                    copied.toggle()
                }
                Menu {
                    Button { saved.set(place, for: .home) } label: {
                        Label { Text("Set as home") } icon: { Icon(.home) }
                    }
                    Button { saved.set(place, for: .work) } label: {
                        Label { Text("Set as work") } icon: { Icon(.work) }
                    }
                } label: {
                    Label { Text("Save") } icon: { Icon(.star, size: 18) }
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glass)
            }
        }
        .font(.subheadline.weight(.semibold))
    }

    private func actionButton(_ title: LocalizedStringKey, icon: DaldalIcon, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title).lineLimit(1).minimumScaleFactor(0.8) } icon: { Icon(icon, size: 18) }
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier(id)
    }

    /// An OpenStreetMap link opens anywhere, with or without Daldal installed.
    private var shareURL: URL {
        let lat = place.latitude, lon = place.longitude
        return URL(string: "https://www.openstreetmap.org/?mlat=\(lat)&mlon=\(lon)#map=17/\(lat)/\(lon)")!
    }
}

/// A place to visit: photo, a short description, a Listen button, and the Wikipedia credit.
private struct GuideDetails: View {
    let place: GuidePlace
    let voice: VoiceGuide
    @State private var expanded = false

    private var languageCode: String { AppLanguage.code }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let url = place.imageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: Color.secondary.opacity(0.1)
                    default: Color.secondary.opacity(0.1).overlay(ProgressView())
                    }
                }
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 16))
                .accessibilityHidden(true)
            }
            if let summary = place.summary(languageCode: languageCode) {
                Text(summary)
                    .font(.body)
                    .lineLimit(expanded ? nil : 4)
                    .onTapGesture { withAnimation(.smooth) { expanded.toggle() } }
                Button { voice.announce(summary, interrupt: true) } label: {
                    Label { Text("Listen") } icon: { Icon(.volume, size: 18) }
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("place.listen")
            }
            if let wiki = place.wikipediaURL(languageCode: languageCode) {
                Link(destination: wiki) {
                    Text("Description from Wikipedia (CC BY-SA 4.0)")
                }
                .font(.caption)
            }
        }
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
