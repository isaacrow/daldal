import CoreLocation
import SwiftUI

/// The home screen: a full-screen 3D map with floating Liquid Glass controls.
struct ExploreView: View {
    @Environment(MapController.self) private var map
    @Environment(SearchStore.self) private var search
    @Environment(SavedPlacesStore.self) private var saved
    @Environment(HeritageStore.self) private var heritage
    @Environment(NavigationModel.self) private var nav
    @Environment(OfflinePackManager.self) private var packs
    @Environment(LocationService.self) private var location
    @Environment(LiveStore.self) private var live

    @State private var selected: Place?
    @State private var isSearching = false
    /// A search result waiting for the search sheet to finish closing before its card opens.
    @State private var pendingSelection: Place?
    @State private var arSite: HeritageSite?
    /// Set by "Directions"; route planning starts once the place card has closed.
    @State private var pendingDirections: Place?
    @State private var showingRoutes = false
    /// Set by "Start"; Drive Mode opens once the route sheet has closed.
    @State private var startAfterRoutes = false
    @State private var showingOfflineMaps = false
    @Namespace private var glass

    private var languageCode: String { AppLanguage.code }

    var body: some View {
        MapCanvas(
            controller: map,
            heritageSites: heritage.sites,
            tiles: packs.installed.map(MapTileSource.offline) ?? .online,
            onLongPress: dropPin,
            onSelectHeritage: { id in
                guard !showingRoutes, let site = heritage.site(id: id) else { return }
                select(site.place(languageCode: languageCode), record: false)
            },
            onSelectRoute: { index in nav.selectedRouteIndex = index },
            onCameraIdle: { center, zoom in
                // Live data only makes sense at street level; it's also what keeps requests small.
                guard zoom >= 11 else { return }
                Task { await live.refresh(around: center) }
            }
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) { SearchBarButton { isSearching = true } }
        .overlay(alignment: .topTrailing) { controls.padding(.top, 72) }
        .overlay(alignment: .bottom) { arrivalBanner }
        .sheet(isPresented: $isSearching, onDismiss: {
            if let place = pendingSelection { select(place, record: true) }
            pendingSelection = nil
        }) {
            SearchSheet { place in
                pendingSelection = place
                isSearching = false
            }
        }
        .sheet(item: $selected, onDismiss: {
            if let place = pendingDirections {
                pendingDirections = nil
                planRoute(to: place)
            } else if selected == nil {
                // Switching straight to another place also dismisses this sheet; keep the new place's pin.
                map.clearPin()
            }
        }) { place in
            PlaceCard(place: place, onOpenAR: openAR, onDirections: { place in
                pendingDirections = place
                selected = nil
            })
                .presentationDetents([.height(250), .medium])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingRoutes, onDismiss: {
            if startAfterRoutes {
                startAfterRoutes = false
                nav.start()
            } else {
                nav.cancelPlanning()
                map.clearPin()
            }
            map.clearRoutes()
        }) {
            RoutePreviewCard(
                onStart: {
                    startAfterRoutes = true
                    showingRoutes = false
                },
                onRetry: { if let place = nav.destination { nav.planRoute(to: place, from: location.location) } }
            )
            .presentationDetents([.height(320), .medium])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingOfflineMaps) {
            OfflineMapsView()
        }
        .fullScreenCover(item: $arSite) { site in
            GeoARView(site: site, languageCode: languageCode)
        }
        .fullScreenCover(isPresented: isDriving) {
            DriveModeView()
        }
        .onChange(of: nav.routes) { showRoutePreview(fit: true) }
        .onChange(of: live.reports) { map.showLive(traffic: live.traffic, reports: live.reports) }
        .onChange(of: live.traffic) { map.showLive(traffic: live.traffic, reports: live.reports) }
        .onChange(of: nav.selectedRouteIndex) { showRoutePreview(fit: false) }
    }

    private var isDriving: Binding<Bool> {
        Binding(
            get: { nav.phase == .navigating || nav.phase == .arrived },
            set: { if !$0, nav.phase != .idle { nav.stop() } }
        )
    }

    private func planRoute(to place: Place) {
        nav.planRoute(to: place, from: location.location)
        showingRoutes = true
    }

    private func showRoutePreview(fit: Bool) {
        let lines = nav.routes.map { route in
            route.geometry.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        }
        if lines.isEmpty { map.clearRoutes() } else { map.showRoutes(lines, selected: nav.selectedRouteIndex, fit: fit) }
    }

    // MARK: Floating controls

    private var controls: some View {
        GlassEffectContainer(spacing: Theme.Spacing.s) {
            VStack(spacing: Theme.Spacing.s) {
                GlassIconButton(icon: .download, label: "Offline maps",
                                isActive: packs.installed != nil) {
                    showingOfflineMaps = true
                }
                .glassEffectID("offline", in: glass)

                GlassIconButton(icon: map.appearance.icon, label: appearanceLabel) {
                    map.appearance = map.appearance.next
                }
                .glassEffectID("appearance", in: glass)

                GlassIconButton(icon: map.is3D ? .cube : .square,
                                label: map.is3D ? "Switch to 2D" : "Switch to 3D",
                                isActive: map.is3D) {
                    map.toggle3D()
                }
                .glassEffectID("dimension", in: glass)

                if map.isRotated {
                    GlassIconButton(icon: .compass, label: "Point north") { map.resetNorth() }
                        .rotationEffect(.degrees(-map.heading))
                        .glassEffectID("compass", in: glass)
                        .glassEffectTransition(.matchedGeometry)
                }

                GlassIconButton(icon: map.isFollowingUser ? .locateFill : .locate,
                                label: "Show my location",
                                isActive: map.isFollowingUser) {
                    map.followUser()
                }
                .glassEffectID("locate", in: glass)
            }
        }
        .padding(.trailing, Theme.Spacing.l)
        .animation(.smooth, value: map.isRotated)
    }

    private var appearanceLabel: LocalizedStringKey {
        switch map.appearance {
        case .auto: "Map theme: automatic"
        case .day: "Map theme: day"
        case .night: "Map theme: night"
        }
    }

    // MARK: Arrival at a heritage site

    @ViewBuilder private var arrivalBanner: some View {
        if let site = heritage.nearby, selected == nil, !isSearching, !showingRoutes {
            ArrivalBanner(
                siteName: site.name(languageCode: languageCode),
                onOpenAR: { arSite = site },
                onDismiss: { withAnimation(.smooth) { heritage.dismissNearby() } }
            )
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Actions

    private func select(_ place: Place, record: Bool) {
        if record { saved.recordVisit(place) }
        selected = place
        map.show(place)
    }

    private func dropPin(at coordinate: CLLocationCoordinate2D) {
        let pin = Place.droppedPin(at: coordinate)
        select(pin, record: false)
        Task {
            // Replace "Dropped pin" with the street name once Photon answers.
            guard let found = await search.reverseGeocode(coordinate), selected?.id == pin.id else { return }
            var named = pin
            named.name = found.name
            named.subtitle = found.subtitle.isEmpty ? pin.subtitle : found.subtitle
            selected = named
        }
    }

    private func openAR(_ place: Place) {
        guard let id = place.heritageID, let site = heritage.site(id: id) else { return }
        selected = nil
        arSite = site
    }
}

/// The glass search capsule at the top of the map.
private struct SearchBarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                Icon(.search, size: 18)
                    .foregroundStyle(.secondary)
                Text("Search in Iraq")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .frame(height: 52)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, Theme.Spacing.l)
        .accessibilityLabel("Search")
    }
}

private struct ArrivalBanner: View {
    let siteName: String
    let onOpenAR: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            CategoryBadge(icon: .heritage, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're at")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(siteName)
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onOpenAR) {
                Label { Text("View in AR") } icon: { Icon(.arView, size: 18) }
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glassProminent)
            Button(action: onDismiss) {
                Icon(.close, size: 14)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(Theme.Spacing.m)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerRadius))
    }
}
