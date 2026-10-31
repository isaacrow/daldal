import SwiftUI

/// Search for places in Iraq, with shortcuts to home, work, heritage sites and recents.
struct SearchSheet: View {
    let onSelect: (Place) -> Void

    @Environment(SearchStore.self) private var search
    @Environment(SavedPlacesStore.self) private var saved
    @Environment(HeritageStore.self) private var heritage
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFieldFocused: Bool
    /// When set, the next chosen place is saved into this slot instead of just opened.
    @State private var settingSlot: SavedPlacesStore.Slot?

    private var languageCode: String { AppLanguage.code }

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            List {
                if let category = search.category, search.query.trimmingCharacters(in: .whitespaces).count < 2 {
                    Section {
                        results
                    } header: {
                        HStack {
                            Text("\(String(localized: category.title)) near you")
                            Spacer()
                            Button("All categories") { search.reset() }.font(.footnote)
                        }
                    }
                } else if search.query.trimmingCharacters(in: .whitespaces).count < 2 {
                    suggestions
                } else {
                    results
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(settingSlot == .home ? "Set home" : settingSlot == .work ? "Set work" : "Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Places, streets, cities")
            .searchFocused($isFieldFocused)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Icon(.close, size: 16) }
                        .accessibilityLabel("Close")
                }
            }
        }
        .onAppear { isFieldFocused = true }
        .onDisappear { search.reset() }
    }

    // MARK: Empty query

    /// A fixed grid (not a sideways scroller, which swallows taps inside a sheet on real phones).
    private var categoryGrid: some View {
        Section("Find nearby") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.s), count: 4), spacing: Theme.Spacing.s) {
                ForEach(NearbyCategory.allCases) { category in
                    Button {
                        isFieldFocused = false
                        search.search(category: category)
                    } label: {
                        VStack(spacing: 4) {
                            Icon(category.icon, size: 20)
                            Text(category.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("category.\(category.rawValue)")
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        }
    }

    @ViewBuilder private var suggestions: some View {
        categoryGrid
        Section {
            savedRow(.home, icon: .home, title: "Home")
            savedRow(.work, icon: .work, title: "Work")
        }

        if !nearestHeritage.isEmpty {
            Section("Heritage sites near you") {
                ForEach(nearestHeritage) { site in
                    let place = site.place(languageCode: languageCode)
                    Button { choose(place) } label: { PlaceRow(place: place, distance: place.distance(from: location.location)) }
                }
            }
        }

        if !saved.recents.isEmpty {
            Section("Recent") {
                ForEach(saved.recents) { place in
                    Button { choose(place) } label: {
                        PlaceRow(place: place, distance: place.distance(from: location.location), icon: .clock)
                    }
                    .swipeActions {
                        Button(role: .destructive) { saved.removeRecent(place) } label: { Text("Remove") }
                    }
                }
            }
        }
    }

    private func savedRow(_ slot: SavedPlacesStore.Slot, icon: DaldalIcon, title: LocalizedStringKey) -> some View {
        Button {
            if let place = saved.place(for: slot) {
                choose(place)
            } else {
                settingSlot = slot
                isFieldFocused = true
            }
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                CategoryBadge(icon: icon, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.rowTitle)
                    Text(saved.place(for: slot)?.name ?? String(localized: "Tap to set"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .tint(.primary)
    }

    private var nearestHeritage: [HeritageSite] {
        guard let here = location.location else { return Array(heritage.sites.filter(\.isWorldHeritage).prefix(5)) }
        return Array(heritage.sites.sorted { $0.location.distance(from: here) < $1.location.distance(from: here) }.prefix(5))
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        if search.failed {
            ContentUnavailableView {
                Label { Text("Search isn't available") } icon: { Icon(.search, size: 36) }
            } description: {
                Text("Check your connection and try again. Offline search arrives with downloadable maps.")
            }
        } else if search.results.isEmpty, !search.isSearching {
            ContentUnavailableView {
                Label { Text("No results in Iraq") } icon: { Icon(.search, size: 36) }
            } description: {
                Text("Try the name in Arabic or English, or a nearby street.")
            }
        } else {
            ForEach(search.results) { place in
                Button { choose(place) } label: { PlaceRow(place: place, distance: place.distance(from: location.location)) }
            }
            if search.isSearching {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            }
        }
    }

    private func choose(_ place: Place) {
        if let slot = settingSlot {
            saved.set(place, for: slot)
            settingSlot = nil
            search.reset()
            return
        }
        onSelect(place)
    }
}

struct PlaceRow: View {
    let place: Place
    let distance: Double?
    var icon: DaldalIcon? = nil

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            CategoryBadge(icon: icon ?? place.category.icon, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !place.subtitle.isEmpty {
                    Text(place.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            if let distance {
                Text(Measurement(value: distance, unit: UnitLength.meters),
                     format: .measurement(width: .abbreviated, usage: .road))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
