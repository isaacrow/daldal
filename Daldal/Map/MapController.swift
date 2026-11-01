import CoreLocation
import MapLibre
import Observation
import UIKit

/// Owns the map's camera and display state, and lets SwiftUI drive the underlying `MLNMapView`.
@Observable
final class MapController {
    @ObservationIgnored weak var mapView: MLNMapView?
    @ObservationIgnored private var pin: MLNPointAnnotation?

    /// 3D: pitched camera + extruded buildings. 2D: top-down with flat footprints.
    var is3D = true
    var appearance: MapAppearance = .auto
    /// Drawn map or satellite photos; remembered between launches.
    var base: MapBaseLayer = MapBaseLayer(rawValue: UserDefaults.standard.string(forKey: "map.base") ?? "") ?? .standard {
        didSet { UserDefaults.standard.set(base.rawValue, forKey: "map.base") }
    }
    /// Camera heading in degrees, used to rotate the compass button.
    private(set) var heading: CLLocationDirection = 0
    private(set) var isFollowingUser = true

    /// True when the map isn't pointing north. 359.5 degrees counts as north.
    var isRotated: Bool { min(heading, 360 - heading) > 1 }

    static let pitch3D: CGFloat = 60
    static let placeViewDistance: CLLocationDistance = 900

    // MARK: Commands

    func toggle3D() {
        is3D.toggle()
        applyBuildingMode()
        guard let mapView else { return }
        let camera = mapView.camera
        camera.pitch = is3D ? Self.pitch3D : 0
        mapView.setCamera(camera, withDuration: 0.45, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
    }

    func followUser() {
        guard let mapView else { return }
        // Second tap while already following switches to heading-up, the way drivers expect.
        let mode: MLNUserTrackingMode = mapView.userTrackingMode == .follow ? .followWithHeading : .follow
        mapView.setUserTrackingMode(mode, animated: true, completionHandler: nil)
    }

    func resetNorth() {
        mapView?.resetNorth()
    }

    func show(_ place: Place) {
        guard let mapView else { return }
        if let pin { mapView.removeAnnotation(pin) }
        let annotation = MLNPointAnnotation()
        annotation.coordinate = place.coordinate
        annotation.title = place.name
        mapView.addAnnotation(annotation)
        pin = annotation

        let camera = MLNMapCamera(
            lookingAtCenter: place.coordinate,
            acrossDistance: Self.placeViewDistance,
            pitch: is3D ? Self.pitch3D : 0,
            heading: mapView.direction
        )
        mapView.fly(to: camera, withDuration: 1.1, completionHandler: nil)
    }

    func clearPin() {
        if let pin { mapView?.removeAnnotation(pin) }
        pin = nil
    }

    // MARK: Called by the map view

    func applyBuildingMode() {
        guard let style = mapView?.style else { return }
        // Offline, every downloaded city has its own copy ("building-3d-basra"), so match by prefix.
        for layer in style.layers {
            if layer.identifier.hasPrefix(MapStyleBuilder.buildings3DLayer) { layer.isVisible = is3D }
            if layer.identifier.hasPrefix(MapStyleBuilder.buildingsFlatLayer) { layer.isVisible = !is3D }
        }
    }

    /// Draws the heritage catalogue as a tappable symbol layer. Called after every style load.
    func installHeritageLayer(sites: [HeritageSite], isDark: Bool, languageCode: String) {
        guard let style = mapView?.style, !sites.isEmpty,
              style.layer(withIdentifier: Self.heritageLayer) == nil else { return }

        let features = sites.map { site in
            let feature = MLNPointFeature()
            feature.coordinate = site.coordinate
            feature.attributes = ["id": site.id, "name": site.name(languageCode: languageCode)]
            return feature
        }
        let source = MLNShapeSource(identifier: Self.heritageLayer, features: features, options: nil)
        style.addSource(source)
        style.setImage(HeritageMarkerImage.make(), forName: "heritage-marker")

        let layer = MLNSymbolStyleLayer(identifier: Self.heritageLayer, source: source)
        layer.iconImageName = NSExpression(forConstantValue: "heritage-marker")
        layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
        layer.text = NSExpression(forKeyPath: "name")
        layer.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
        layer.textFontSize = NSExpression(forConstantValue: 12)
        layer.textAnchor = NSExpression(forConstantValue: "top")
        layer.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.4)))
        layer.textOptional = NSExpression(forConstantValue: true) // Hide labels, never icons, when crowded.
        layer.textColor = NSExpression(forConstantValue: isDark ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.2, alpha: 1))
        layer.textHaloColor = NSExpression(forConstantValue: isDark ? UIColor.black : UIColor.white)
        layer.textHaloWidth = NSExpression(forConstantValue: 1.5)
        style.addLayer(layer)
    }

    static let heritageLayer = "heritage"
    static let guideLayer = "guide-landmarks"
    static let guideLabelLayer = "guide-labels"

    /// Places to visit as 3D landmarks: a gold three-step ziggurat rising from each, named above.
    func installGuideLayer(places: [GuidePlace], isDark: Bool, languageCode: String) {
        guard let style = mapView?.style, !places.isEmpty,
              style.layer(withIdentifier: Self.guideLayer) == nil else { return }

        // Tiers: (half-width in metres, base height, top height).
        let tiers: [(Double, Double, Double)] = [(28, 0, 12), (20, 12, 22), (12, 22, 30)]
        var blocks: [MLNPolygonFeature] = []
        var labels: [MLNPointFeature] = []
        for place in places {
            let c = place.coordinate
            let metresPerDegreeLon = 111_320 * cos(c.latitude * .pi / 180)
            for (half, base, top) in tiers {
                let dLat = half / 111_320, dLon = half / metresPerDegreeLon
                var ring = [
                    CLLocationCoordinate2D(latitude: c.latitude - dLat, longitude: c.longitude - dLon),
                    CLLocationCoordinate2D(latitude: c.latitude - dLat, longitude: c.longitude + dLon),
                    CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon),
                    CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude - dLon),
                    CLLocationCoordinate2D(latitude: c.latitude - dLat, longitude: c.longitude - dLon),
                ]
                let block = MLNPolygonFeature(coordinates: &ring, count: UInt(ring.count))
                block.attributes = ["gid": place.id, "base": base, "top": top]
                blocks.append(block)
            }
            let label = MLNPointFeature()
            label.coordinate = c
            label.attributes = ["gid": place.id, "name": place.name(languageCode: languageCode)]
            labels.append(label)
        }

        let blockSource = MLNShapeSource(identifier: Self.guideLayer, shape: MLNShapeCollectionFeature(shapes: blocks), options: nil)
        let labelSource = MLNShapeSource(identifier: Self.guideLabelLayer, shape: MLNShapeCollectionFeature(shapes: labels), options: nil)
        style.addSource(blockSource)
        style.addSource(labelSource)

        let landmark = MLNFillExtrusionStyleLayer(identifier: Self.guideLayer, source: blockSource)
        landmark.fillExtrusionColor = NSExpression(forConstantValue: UIColor(red: 0.89, green: 0.69, blue: 0.29, alpha: 1))
        landmark.fillExtrusionBase = NSExpression(forKeyPath: "base")
        landmark.fillExtrusionHeight = NSExpression(forKeyPath: "top")
        landmark.fillExtrusionOpacity = NSExpression(forConstantValue: 0.95)
        landmark.minimumZoomLevel = 11
        if let labelsAnchor = style.layer(withIdentifier: MapStyleBuilder.labelsAnchor) {
            style.insertLayer(landmark, below: labelsAnchor)
        } else {
            style.addLayer(landmark)
        }

        let names = MLNSymbolStyleLayer(identifier: Self.guideLabelLayer, source: labelSource)
        names.text = NSExpression(forKeyPath: "name")
        names.textFontNames = NSExpression(forConstantValue: ["NotoSansBold"])
        names.textFontSize = NSExpression(forConstantValue: 13)
        names.textAnchor = NSExpression(forConstantValue: "bottom")
        names.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: -2.2)))
        names.textColor = NSExpression(forConstantValue: UIColor(red: 0.97, green: 0.82, blue: 0.45, alpha: 1))
        names.textHaloColor = NSExpression(forConstantValue: isDark ? UIColor.black : UIColor(white: 0.15, alpha: 1))
        names.textHaloWidth = NSExpression(forConstantValue: 1.6)
        names.textOptional = NSExpression(forConstantValue: true)
        names.minimumZoomLevel = 12
        style.addLayer(names)
    }

    static let landmarkModelLayer = "landmark-models"
    static let pinsLayer = "result-pins"
    static let landmarkGroundLayer = "landmark-ground"

    /// From street zoom, each model lies on the ground at its real size, seen from above, and turns and tilts
    /// with the map like the buildings around it. (MapLibre can't draw 3D meshes, so this is the closest true-size
    /// view; the 3D model itself is on the place card and in AR.)
    private func installLandmarkGround(in style: MLNStyle) {
        let grounded = landmarkIcons.filter { $0.top != nil && ($0.footprintWidth ?? 0) > 0 }
        guard !grounded.isEmpty else { return }
        let features = grounded.map { icon in
            style.setImage(icon.top!, forName: "landmark-top-\(icon.id)")
            let feature = MLNPointFeature()
            feature.coordinate = icon.coordinate
            // The picture is 128 points wide; at zoom z one point covers 40,075,017 * cos(lat) / (512 * 2^z) metres.
            // So its scale is k * 2^z with k = width * 512 / (40,075,017 * cos(lat) * 128).
            let k = icon.footprintWidth! * 512 / (40_075_017 * cos(icon.coordinate.latitude * .pi / 180) * 128)
            feature.attributes = ["icon": "landmark-top-\(icon.id)", "k": k, icon.isGuide ? "gid" : "hid": icon.id]
            return feature
        }
        let shape = MLNShapeCollectionFeature(shapes: features)
        if let source = style.source(withIdentifier: Self.landmarkGroundLayer) as? MLNShapeSource {
            source.shape = shape
            return
        }
        let source = MLNShapeSource(identifier: Self.landmarkGroundLayer, shape: shape, options: nil)
        style.addSource(source)
        let layer = MLNSymbolStyleLayer(identifier: Self.landmarkGroundLayer, source: source)
        layer.iconImageName = NSExpression(forKeyPath: "icon")
        layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
        layer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
        layer.iconRotationAlignment = NSExpression(forConstantValue: "map")
        layer.iconPitchAlignment = NSExpression(forConstantValue: "map")
        layer.iconScale = NSExpression(
            format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 2, %@)",
            [15: NSExpression(format: "k * 32768"), 22: NSExpression(format: "k * 4194304")])
        layer.minimumZoomLevel = 15.5
        if let names = style.layer(withIdentifier: Self.guideLabelLayer) {
            style.insertLayer(layer, below: names)
        } else {
            style.addLayer(layer)
        }
    }

    @ObservationIgnored private var pins: [Place] = []
    @ObservationIgnored private var roadFeatures: [RoadFeature] = []
    @ObservationIgnored private var roughSpots: [RoughSpot] = []

    /// The automatic pothole map: rough spots felt while driving.
    func showRoughSpots(_ spots: [RoughSpot]) {
        roughSpots = spots
        guard let style = mapView?.style else { return }
        RoughRoadStore.draw(spots, in: style)
    }

    /// Speed cameras and stop signs, as small road signs from street zoom.
    func showRoadFeatures(_ features: [RoadFeature]) {
        roadFeatures = features
        guard let style = mapView?.style else { return }
        RoadFeatureStore.draw(features, in: style)
    }

    /// Marks search or assistant results on the map with their category badge, and frames them.
    func showPins(_ places: [Place], fit: Bool) {
        pins = places
        reinstallPins()
        guard fit, let mapView, !places.isEmpty else { return }
        var coordinates = places.prefix(12).map(\.coordinate)
        if let here = mapView.userLocation?.location?.coordinate { coordinates.append(here) }
        if coordinates.count == 1 {
            mapView.setCenter(coordinates[0], zoomLevel: 15, animated: true)
        } else {
            mapView.setVisibleCoordinates(&coordinates, count: UInt(coordinates.count),
                                          edgePadding: UIEdgeInsets(top: 140, left: 48, bottom: 360, right: 80), animated: true)
        }
    }

    func reinstallPins() {
        guard let style = mapView?.style else { return }
        if !roadFeatures.isEmpty { RoadFeatureStore.draw(roadFeatures, in: style) }
        if !roughSpots.isEmpty { RoughRoadStore.draw(roughSpots, in: style) }
        let features = pins.map { place in
            let name = "pin-\(place.category.rawValue)"
            if style.image(forName: name) == nil { style.setImage(ResultPinImage.make(place.category.icon), forName: name) }
            let feature = MLNPointFeature()
            feature.coordinate = place.coordinate
            feature.attributes = ["pid": place.id, "icon": name, "name": place.name]
            return feature
        }
        let shape = MLNShapeCollectionFeature(shapes: features)
        if let source = style.source(withIdentifier: Self.pinsLayer) as? MLNShapeSource {
            source.shape = shape
            return
        }
        let source = MLNShapeSource(identifier: Self.pinsLayer, shape: shape, options: nil)
        style.addSource(source)
        let layer = MLNSymbolStyleLayer(identifier: Self.pinsLayer, source: source)
        layer.iconImageName = NSExpression(forKeyPath: "icon")
        layer.iconAnchor = NSExpression(forConstantValue: "bottom")
        layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
        layer.text = NSExpression(forKeyPath: "name")
        layer.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
        layer.textFontSize = NSExpression(forConstantValue: 11)
        layer.textAnchor = NSExpression(forConstantValue: "top")
        layer.textOptional = NSExpression(forConstantValue: true)
        layer.textHaloColor = NSExpression(forConstantValue: UIColor.white)
        layer.textHaloWidth = NSExpression(forConstantValue: 1.4)
        style.addLayer(layer)
    }

    /// A monument's 3D model drawn on the map as a picture of the model standing at its place.
    struct LandmarkIcon {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let image: UIImage
        /// From straight above, with the real footprint in metres: drawn flat on the ground at street zoom.
        var top: UIImage? = nil
        var footprintWidth: Double? = nil
        /// A city-guide place (else a heritage site): decides which card a tap opens.
        let isGuide: Bool
    }

    @ObservationIgnored private var landmarkIcons: [LandmarkIcon] = []

    func showLandmarkIcons(_ icons: [LandmarkIcon]) {
        landmarkIcons = icons
        installLandmarkIcons()
    }

    /// Draws (or redraws after a style reload) the landmark pictures, growing with zoom, and hides the
    /// placeholder ziggurat of every guide place that has a real model.
    func installLandmarkIcons() {
        guard let style = mapView?.style, !landmarkIcons.isEmpty else { return }
        let features = landmarkIcons.map { icon in
            style.setImage(icon.image, forName: "landmark-\(icon.id)")
            let feature = MLNPointFeature()
            feature.coordinate = icon.coordinate
            feature.attributes = ["icon": "landmark-\(icon.id)", icon.isGuide ? "gid" : "hid": icon.id]
            return feature
        }
        let shape = MLNShapeCollectionFeature(shapes: features)
        if let source = style.source(withIdentifier: Self.landmarkModelLayer) as? MLNShapeSource {
            source.shape = shape
        } else {
            let source = MLNShapeSource(identifier: Self.landmarkModelLayer, shape: shape, options: nil)
            style.addSource(source)
            let layer = MLNSymbolStyleLayer(identifier: Self.landmarkModelLayer, source: source)
            layer.iconImageName = NSExpression(forKeyPath: "icon")
            layer.iconAnchor = NSExpression(forConstantValue: "bottom")
            layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            layer.iconScale = NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
                                           [11: 0.35, 14: 0.7, 17: 1.3])
            layer.minimumZoomLevel = 11
            layer.maximumZoomLevel = 15.5
            if let names = style.layer(withIdentifier: Self.guideLabelLayer) {
                style.insertLayer(layer, below: names)
            } else {
                style.addLayer(layer)
            }
        }
        installLandmarkGround(in: style)
        let modelled = landmarkIcons.filter(\.isGuide).map(\.id)
        if let ziggurats = style.layer(withIdentifier: Self.guideLayer) as? MLNFillExtrusionStyleLayer {
            ziggurats.predicate = NSPredicate(format: "NOT (gid IN %@)", modelled)
        }
    }
    static let routeLayer = "route-preview"

    @ObservationIgnored private var previewRoutes: (routes: [[CLLocationCoordinate2D]], selected: Int)?

    /// Draws route options. The selected one is highlighted and drawn on top; tapping another selects it.
    func showRoutes(_ routes: [[CLLocationCoordinate2D]], selected: Int, fit: Bool) {
        previewRoutes = (routes, selected)
        guard let mapView, let style = mapView.style else { return }

        // Unselected first, so the selected route is drawn last (on top).
        let order = routes.indices.filter { $0 != selected } + (routes.indices.contains(selected) ? [selected] : [])
        let features: [MLNPolylineFeature] = order.map { index in
            var coordinates = routes[index]
            let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
            feature.attributes = ["index": index, "selected": index == selected]
            return feature
        }
        let shape = MLNShapeCollectionFeature(shapes: features)

        if let source = style.source(withIdentifier: Self.routeLayer) as? MLNShapeSource {
            source.shape = shape
        } else {
            let source = MLNShapeSource(identifier: Self.routeLayer, shape: shape, options: nil)
            style.addSource(source)
            let accent = UIColor(named: "AccentColor") ?? .systemTeal
            let casing = MLNLineStyleLayer(identifier: Self.routeLayer + "-casing", source: source)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineWidth = NSExpression(format: "TERNARY(selected == YES, 12, 9)")
            casing.lineCap = NSExpression(forConstantValue: "round")
            casing.lineJoin = NSExpression(forConstantValue: "round")
            let line = MLNLineStyleLayer(identifier: Self.routeLayer, source: source)
            line.lineColor = NSExpression(format: "TERNARY(selected == YES, %@, %@)", accent, UIColor.systemGray2)
            line.lineWidth = NSExpression(format: "TERNARY(selected == YES, 7, 5)")
            line.lineCap = NSExpression(forConstantValue: "round")
            line.lineJoin = NSExpression(forConstantValue: "round")
            // Below labels and heritage markers, so street names stay readable on top of the route.
            if let below = style.layer(withIdentifier: "road-label") {
                style.insertLayer(casing, below: below)
                style.insertLayer(line, below: below)
            } else {
                style.addLayer(casing)
                style.addLayer(line)
            }
        }

        drawRouteTraffic()

        guard fit, routes.indices.contains(selected) else { return }
        var coordinates = routes[selected]
        let camera = mapView.camera
        camera.pitch = 0 // A flat overview reads better when comparing routes.
        mapView.setCamera(camera, animated: false)
        mapView.setVisibleCoordinates(&coordinates, count: UInt(coordinates.count),
                                      edgePadding: UIEdgeInsets(top: 140, left: 48, bottom: 340, right: 80),
                                      animated: true)
    }

    func clearRoutes() {
        previewRoutes = nil
        (mapView?.style?.source(withIdentifier: Self.routeLayer) as? MLNShapeSource)?.shape = nil
        drawRouteTraffic()
    }

    /// Colours the selected route by live traffic (nothing when there's no route or no traffic data).
    private func drawRouteTraffic() {
        guard let style = mapView?.style else { return }
        let route = previewRoutes.flatMap { $0.routes.indices.contains($0.selected) ? $0.routes[$0.selected] : nil } ?? []
        RouteTraffic.draw(RouteTraffic.stretches(along: route, traffic: liveTraffic), in: style, above: Self.routeLayer)
    }

    @ObservationIgnored private var liveTraffic: Data?
    @ObservationIgnored private var liveReports: [LiveReport] = []

    /// Shows live traffic and reports. Kept so they can be redrawn after a style reload.
    func showLive(traffic: Data?, reports: [LiveReport]) {
        liveTraffic = traffic
        liveReports = reports
        guard let style = mapView?.style else { return }
        LiveLayers.updateTraffic(traffic, in: style)
        LiveLayers.updateReports(reports, in: style)
        drawRouteTraffic()
    }

    func reinstallLive() {
        showLive(traffic: liveTraffic, reports: liveReports)
    }

    /// The map's centre once it stops moving, used to fetch live data for the visible area.
    var visibleCenter: CLLocationCoordinate2D? { mapView?.centerCoordinate }

    /// Restores route options after a style reload (theme or tile source change).
    func reinstallRoutes() {
        if let previewRoutes { showRoutes(previewRoutes.routes, selected: previewRoutes.selected, fit: false) }
    }

    func cameraDidChange(heading: CLLocationDirection) {
        // Avoid invalidating SwiftUI on every frame for sub-degree changes.
        if abs(heading - self.heading) > 0.5 { self.heading = heading }
    }

    func trackingModeDidChange(_ mode: MLNUserTrackingMode) {
        isFollowingUser = mode != .none
    }
}
