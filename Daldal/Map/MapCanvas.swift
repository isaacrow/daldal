import CoreLocation
import MapLibre
import SwiftUI

/// The full-screen MapLibre map. All interaction goes through `MapController`.
struct MapCanvas: UIViewRepresentable {
    let controller: MapController
    var heritageSites: [HeritageSite] = []
    var guidePlaces: [GuidePlace] = []
    var tiles: MapTileSource = .online
    var onLongPress: (CLLocationCoordinate2D) -> Void = { _ in }
    var onSelectHeritage: (String) -> Void = { _ in }
    var onSelectGuide: (String) -> Void = { _ in }
    var onSelectRoute: (Int) -> Void = { _ in }
    /// A search or assistant result pinned on the map.
    var onSelectPin: (String) -> Void = { _ in }
    /// A shop, restaurant, mosque... drawn on the map.
    var onSelectPlace: (Place) -> Void = { _ in }
    var onCameraIdle: (CLLocationCoordinate2D, Double) -> Void = { _, _ in }

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        mapView.maximumZoomLevel = 19.5
        // Start over Baghdad; tracking moves the camera to the user as soon as there is a fix.
        mapView.setCenter(Region.defaultCenter, zoomLevel: 12, animated: false)

        // Our own glass controls replace the compass; attribution stays visible (required by ODbL).
        mapView.compassView.isHidden = true
        mapView.logoView.isHidden = true
        mapView.attributionButtonPosition = .bottomLeft
        mapView.attributionButtonMargins = CGPoint(x: 12, y: 12)

        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        press.minimumPressDuration = 0.45
        mapView.addGestureRecognizer(press)

        // Single taps pick heritage markers, but must not swallow the map's double-tap zoom.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        for case let doubleTap as UITapGestureRecognizer in mapView.gestureRecognizers ?? [] where doubleTap.numberOfTapsRequired == 2 {
            tap.require(toFail: doubleTap)
        }
        mapView.addGestureRecognizer(tap)

        controller.mapView = mapView
        context.coordinator.applyStyle(to: mapView, isDark: isDark)
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyStyle(to: mapView, isDark: isDark)
    }

    private var isDark: Bool {
        switch controller.appearance {
        case .auto: colorScheme == .dark
        case .day: false
        case .night: true
        }
    }

    fileprivate var languageCode: String {
        AppLanguage.code
    }

    // MapLibre calls its delegate on the main thread; the module predates Swift concurrency annotations.
    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        var parent: MapCanvas
        private var loadedStyleKey: String?
        private var isDark = false
        /// The map jumps to the user on the first good fix, so the app always opens where you are.
        private var centeredOnUser = false

        init(_ parent: MapCanvas) { self.parent = parent }

        /// Reloads the style only when the theme, language or tile source actually changes.
        func applyStyle(to mapView: MLNMapView, isDark: Bool) {
            let key = "\(isDark)-\(parent.languageCode)-\(parent.tiles.cacheKey)-\(parent.controller.base.rawValue)"
            guard key != loadedStyleKey else { return }
            loadedStyleKey = key
            self.isDark = isDark
            do {
                mapView.styleURL = try MapStyleBuilder.styleURL(isDark: isDark, languageCode: parent.languageCode,
                                                                tiles: parent.tiles, base: parent.controller.base)
            } catch {
                assertionFailure("Could not write map style: \(error)")
            }
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView = gesture.view as? MLNMapView else { return }
            let point = gesture.location(in: mapView)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            parent.onLongPress(mapView.convert(point, toCoordinateFrom: mapView))
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = gesture.view as? MLNMapView else { return }
            let point = gesture.location(in: mapView)
            let hitArea = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let pins = mapView.visibleFeatures(in: hitArea, styleLayerIdentifiers: [MapController.pinsLayer])
            if let id = pins.first?.attribute(forKey: "pid") as? String {
                parent.onSelectPin(id)
                return
            }
            // A landmark's 3D model on the map opens its card.
            let models = mapView.visibleFeatures(in: hitArea, styleLayerIdentifiers: [MapController.landmarkModelLayer,
                                                                                      MapController.landmarkGroundLayer])
            if let id = models.first?.attribute(forKey: "gid") as? String {
                parent.onSelectGuide(id)
                return
            }
            if let id = models.first?.attribute(forKey: "hid") as? String {
                parent.onSelectHeritage(id)
                return
            }
            let features = mapView.visibleFeatures(in: hitArea, styleLayerIdentifiers: [MapController.heritageLayer])
            if let id = features.first?.attribute(forKey: "id") as? String {
                parent.onSelectHeritage(id)
                return
            }
            // Places to visit: the 3D landmark or its name.
            let landmarks = mapView.visibleFeatures(in: hitArea, styleLayerIdentifiers: [MapController.guideLayer, MapController.guideLabelLayer])
            if let id = landmarks.first?.attribute(forKey: "gid") as? String {
                parent.onSelectGuide(id)
                return
            }
            // A place drawn on the map (shop, restaurant, clinic...).
            let poiLayers = Set(mapView.style?.layers.map(\.identifier).filter { $0.hasPrefix(PoiIcons.layer) } ?? [])
            if let poi = mapView.visibleFeatures(in: hitArea, styleLayerIdentifiers: poiLayers).first,
               let name = poi.attribute(forKey: "name") as? String {
                let localized = poi.attribute(forKey: "name:\(parent.languageCode)") as? String
                let kind = poi.attribute(forKey: "class") as? String
                let c = poi.coordinate
                parent.onSelectPlace(Place(id: "poi:\(c.latitude),\(c.longitude)", name: localized ?? name,
                                           subtitle: (poi.attribute(forKey: "subclass") as? String)?
                                               .replacingOccurrences(of: "_", with: " ").capitalized ?? "",
                                           latitude: c.latitude, longitude: c.longitude,
                                           category: PoiIcons.category(forClass: kind)))
                return
            }
            // Tapping an alternative route selects it, as in every navigation app.
            let routes = mapView.visibleFeatures(in: hitArea, styleLayerIdentifiers: [MapController.routeLayer])
            if let index = (routes.first?.attribute(forKey: "index") as? NSNumber)?.intValue {
                parent.onSelectRoute(index)
            }
        }

        // MARK: MLNMapViewDelegate

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            parent.controller.applyBuildingMode()
            parent.controller.installHeritageLayer(sites: parent.heritageSites, isDark: isDark, languageCode: parent.languageCode)
            parent.controller.installGuideLayer(places: parent.guidePlaces, isDark: isDark, languageCode: parent.languageCode)
            PoiIcons.install(in: style)
            parent.controller.installLandmarkIcons()
            parent.controller.reinstallPins()
            parent.controller.reinstallRoutes()
            parent.controller.reinstallLive()
            if parent.controller.is3D, mapView.camera.pitch < 1 {
                let camera = mapView.camera
                camera.pitch = MapController.pitch3D
                mapView.setCamera(camera, animated: false)
            }
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            parent.controller.cameraDidChange(heading: mapView.direction)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            parent.controller.cameraDidChange(heading: mapView.direction)
            parent.onCameraIdle(mapView.centerCoordinate, mapView.zoomLevel)
        }

        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            parent.controller.trackingModeDidChange(mode)
        }

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            guard let location = userLocation?.location, location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy < 200 else { return }
            if !centeredOnUser {
                centeredOnUser = true
                mapView.setCenter(location.coordinate, zoomLevel: 15.5, animated: false)
                mapView.setUserTrackingMode(.follow, animated: false, completionHandler: nil)
            }
        }

        func mapView(_ mapView: MLNMapView, imageFor annotation: any MLNAnnotation) -> MLNAnnotationImage? {
            let id = "daldal-pin"
            if let reused = mapView.dequeueReusableAnnotationImage(withIdentifier: id) { return reused }
            return MLNAnnotationImage(image: PinImage.make(), reuseIdentifier: id)
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: any MLNAnnotation) -> Bool {
            false // The place card is our callout.
        }
    }
}

/// Draws the selected-place marker. The image is padded so its tip sits at the centre,
/// because MapLibre centres annotation images on the coordinate.
enum PinImage {
    static func make() -> UIImage {
        let width: CGFloat = 36, height: CGFloat = 46
        let size = CGSize(width: width, height: height * 2)
        return UIGraphicsImageRenderer(size: size).image { context in
            let r = width / 2
            let path = UIBezierPath()
            path.addArc(withCenter: CGPoint(x: r, y: r), radius: r - 3, startAngle: .pi * 0.8, endAngle: .pi * 0.2, clockwise: true)
            path.addLine(to: CGPoint(x: r, y: height))
            path.close()

            let cg = context.cgContext
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.3).cgColor)
            (UIColor(named: "AccentColor") ?? .systemTeal).setFill()
            path.fill()
            cg.restoreGState()

            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: r - 6, y: r - 6, width: 12, height: 12)).fill()
        }
    }
}

/// The map marker for heritage sites: the ziggurat icon on a sand-coloured disc.
enum HeritageMarkerImage {
    static func make() -> UIImage {
        let size: CGFloat = 30
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            let disc = CGRect(x: 1, y: 1, width: size - 2, height: size - 2)
            UIColor(red: 0.72, green: 0.49, blue: 0.24, alpha: 1).setFill() // Mud-brick ochre
            UIBezierPath(ovalIn: disc).fill()
            UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: disc)
            ring.lineWidth = 2
            ring.stroke()
            UIImage(named: DaldalIcon.heritage.assetName)?
                .withTintColor(.white)
                .draw(in: disc.insetBy(dx: 7, dy: 7))
        }
    }
}

/// A teardrop pin with a category glyph, for search and assistant results.
enum ResultPinImage {
    static func make(_ icon: DaldalIcon) -> UIImage {
        let size = CGSize(width: 32, height: 40)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let accent = UIColor(named: "AccentColor") ?? .systemTeal
            let pin = UIBezierPath()
            pin.move(to: CGPoint(x: 16, y: 39))
            pin.addCurve(to: CGPoint(x: 2, y: 15), controlPoint1: CGPoint(x: 9, y: 31), controlPoint2: CGPoint(x: 2, y: 24))
            pin.addArc(withCenter: CGPoint(x: 16, y: 15), radius: 14, startAngle: .pi, endAngle: 0, clockwise: true)
            pin.addCurve(to: CGPoint(x: 16, y: 39), controlPoint1: CGPoint(x: 30, y: 24), controlPoint2: CGPoint(x: 23, y: 31))
            pin.close()
            accent.setFill()
            pin.fill()
            UIColor.white.setStroke()
            pin.lineWidth = 2
            pin.stroke()
            UIImage(named: icon.assetName)?.withTintColor(.white).draw(in: CGRect(x: 8, y: 7, width: 16, height: 16))
        }
    }
}
