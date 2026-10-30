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
        style.layer(withIdentifier: MapStyleBuilder.buildings3DLayer)?.isVisible = is3D
        style.layer(withIdentifier: MapStyleBuilder.buildingsFlatLayer)?.isVisible = !is3D
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
