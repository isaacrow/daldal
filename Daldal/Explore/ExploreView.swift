import CoreLocation
import SwiftUI

/// The home screen: a full-screen 3D map with floating Liquid Glass controls.
struct ExploreView: View {
    @Environment(MapController.self) private var map
    @Environment(SearchStore.self) private var search
    @Environment(SavedPlacesStore.self) private var saved
    @Environment(HeritageStore.self) private var heritage
    @Environment(NavigationModel.self) private var nav
    @Environment(CityMapsStore.self) private var cities
    @Environment(Connectivity.self) private var connectivity
    @Environment(LocationService.self) private var location
    @Environment(LiveStore.self) private var live

    /// What the bottom panel shows. One sheet whose content changes, like Apple Maps: switching content
    /// never closes and reopens a sheet, which iOS ignores when it happens mid-animation.
    enum Panel: Equatable {
        case search
        case place(Place)
        case routes
        case maps
    }

    @State private var panel: Panel?
    @State private var detent: PresentationDetent = .height(270)
    /// Heritage AR opened from a place card (presented on top of the panel).
    @State private var arSite: HeritageSite?
    /// Walking AR navigation opened from a place card (presented on top of the panel).
    @State private var walkDestination: Place?
    /// Drive Scan. Presented from the panel when one is open, else from the map, so it never collides with it.
    @State private var scanning = false
    /// Heritage AR opened from the "You're at" banner (no panel showing).
    @State private var bannerARSite: HeritageSite?
    @Namespace private var glass

    private var languageCode: String { AppLanguage.code }

    /// Online tiles when there's signal; downloaded cities when there isn't, so they never go blank.
    private var tileSource: MapTileSource {
        connectivity.isOnline || cities.installedCities.isEmpty ? .online : .offline(cities.installedCities)
    }

    private var selected: Place? {
        if case .place(let place) = panel { place } else { nil }
    }

    var body: some View {
        // Drive Mode replaces the map screen instead of being presented over it, so starting a trip
        // can never collide with the closing route panel.
        if nav.phase == .navigating || nav.phase == .arrived {
            DriveModeView()
                .transition(.opacity)
        } else {
            explore
        }
    }

    private var explore: some View {
        MapCanvas(
            controller: map,
            heritageSites: heritage.sites,
            tiles: tileSource,
            onLongPress: dropPin,
            onSelectHeritage: { id in
                guard panel != .routes, let site = heritage.site(id: id) else { return }
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
        .overlay(alignment: .top) { SearchBarButton { show(.search, at: .large) } }
        .overlay(alignment: .topTrailing) { controls.padding(.top, 72) }
        .overlay(alignment: .bottom) { arrivalBanner }
        .sheet(isPresented: panelPresented) {
            panelContent
                .presentationDetents([.height(270), .height(340), .medium, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .fullScreenCover(item: $arSite) { site in
                    GeoARView(site: site, languageCode: languageCode)
                }
                .fullScreenCover(isPresented: scanBinding(whenPanelOpen: true)) {
                    DriveScanView(voice: nav.voice)
                }
                .fullScreenCover(item: $walkDestination) { place in
                    WalkARView(destination: place,
                               provider: DaldalRouteProvider(cities: { [cities] in cities.installedCities }),
                               voice: nav.voice)
                }
        }
        .fullScreenCover(item: $bannerARSite) { site in
            GeoARView(site: site, languageCode: languageCode)
        }
        .fullScreenCover(isPresented: scanBinding(whenPanelOpen: false)) {
            DriveScanView(voice: nav.voice)
        }
        .task { openPlaceForUITest() }
        .onChange(of: nav.routes) { showRoutePreview(fit: true) }
        .onChange(of: live.reports) { map.showLive(traffic: live.traffic, reports: live.reports) }
        .onChange(of: live.traffic) { map.showLive(traffic: live.traffic, reports: live.reports) }
        .onChange(of: nav.selectedRouteIndex) { showRoutePreview(fit: false) }
    }

    @ViewBuilder private var panelContent: some View {
        switch panel {
        case .search:
            SearchSheet { place in select(place, record: true) }
        case .place(let place):
            PlaceCard(
                place: place,
                onOpenAR: openAR,
                onDirections: { place in planRoute(to: place) },
                onWalk: { place in walkDestination = place }
            )
        case .routes:
            RoutePreviewCard(
                onStart: start,
                onRetry: { if let place = nav.destination { nav.planRoute(to: place, from: location.location) } }
            )
        case .maps:
            OfflineMapsView()
        case nil:
            EmptyView()
        }
    }

    /// UI tests launch with `-uitest-heritage <English name>` to open that site's card directly.
    private func openPlaceForUITest() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uitest-heritage"), args.indices.contains(i + 1),
              let site = heritage.sites.first(where: { $0.nameEn == args[i + 1] }) else { return }
        select(site.place(languageCode: languageCode), record: false)
    }

    private func scanBinding(whenPanelOpen: Bool) -> Binding<Bool> {
        Binding(
            get: { scanning && (panel != nil) == whenPanelOpen },
            set: { if !$0 { scanning = false } }
        )
    }

    private var panelPresented: Binding<Bool> {
        Binding(
            get: { panel != nil },
            set: { presented in if !presented { panelClosed() } }
        )
    }

    /// The user swiped the panel away.
    private func panelClosed() {
        if panel == .routes {
            nav.cancelPlanning()
            map.clearRoutes()
        }
        if case .place = panel { map.clearPin() }
        if panel == .routes { map.clearPin() }
        panel = nil
    }

    private func show(_ newPanel: Panel, at newDetent: PresentationDetent) {
        detent = newDetent
        panel = newPanel
    }

    private func start() {
        panel = nil
        map.clearRoutes()
        withAnimation(.smooth) { nav.start() }
    }

    private func planRoute(to place: Place) {
        nav.planRoute(to: place, from: location.location)
        show(.routes, at: .height(340))
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
                                isActive: !cities.installedCities.isEmpty) {
                    show(.maps, at: .large)
                }
                .glassEffectID("offline", in: glass)

                GlassIconButton(icon: .scan, label: "Drive Scan") { scanning = true }
                    .glassEffectID("scan", in: glass)
                    .accessibilityIdentifier("map.scan")

                GlassIconButton(icon: .layers, label: map.base == .satellite ? "Show map" : "Show satellite",
                                isActive: map.base == .satellite) {
                    map.base = map.base == .satellite ? .standard : .satellite
                }
                .glassEffectID("satellite", in: glass)

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
        if let site = heritage.nearby, panel == nil {
            ArrivalBanner(
                siteName: site.name(languageCode: languageCode),
                onOpenAR: { bannerARSite = site },
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
        show(.place(place), at: .height(270))
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
            panel = .place(named)
        }
    }

    private func openAR(_ place: Place) {
        // Presented over the panel, which stays open underneath: nothing has to close first.
        guard let id = place.heritageID, let site = heritage.site(id: id) else { return }
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
