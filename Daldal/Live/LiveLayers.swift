import MapLibre
import UIKit

/// Draws live traffic and reports into any MapLibre style: the Explore map and the Drive Mode map share this.
enum LiveLayers {
    static let trafficLayer = "live-traffic"
    static let reportsLayer = "live-reports"

    /// Congested roads as coloured lines on top of the road, under street names.
    static func updateTraffic(_ geojson: Data?, in style: MLNStyle) {
        let shape = geojson.flatMap { try? MLNShape(data: $0, encoding: String.Encoding.utf8.rawValue) }
        if let source = style.source(withIdentifier: trafficLayer) as? MLNShapeSource {
            source.shape = shape
            return
        }
        let source = MLNShapeSource(identifier: trafficLayer, shape: shape, options: nil)
        style.addSource(source)
        let line = MLNLineStyleLayer(identifier: trafficLayer, source: source)
        // level: 1 slow, 2 heavy, 3 standstill.
        line.lineColor = NSExpression(
            format: "TERNARY(level == 1, %@, TERNARY(level == 2, %@, %@))",
            UIColor(red: 0.96, green: 0.62, blue: 0.10, alpha: 1),
            UIColor(red: 0.89, green: 0.25, blue: 0.24, alpha: 1),
            UIColor(red: 0.55, green: 0.10, blue: 0.12, alpha: 1)
        )
        line.lineWidth = NSExpression(forConstantValue: 4.5)
        line.lineCap = NSExpression(forConstantValue: "round")
        line.lineJoin = NSExpression(forConstantValue: "round")
        line.lineOpacity = NSExpression(forConstantValue: 0.9)
        insertBelowLabels(line, in: style)
    }

    static func updateReports(_ reports: [LiveReport], in style: MLNStyle) {
        let features: [MLNPointFeature] = reports.map { report in
            let feature = MLNPointFeature()
            feature.coordinate = report.coordinate
            feature.attributes = ["id": report.id, "icon": "report-\(report.type.rawValue)"]
            return feature
        }
        let shape = MLNShapeCollectionFeature(shapes: features)
        if let source = style.source(withIdentifier: reportsLayer) as? MLNShapeSource {
            source.shape = shape
            return
        }
        for type in ReportType.allCases {
            style.setImage(ReportMarkerImage.make(type), forName: "report-\(type.rawValue)")
        }
        let source = MLNShapeSource(identifier: reportsLayer, shape: shape, options: nil)
        style.addSource(source)
        let symbols = MLNSymbolStyleLayer(identifier: reportsLayer, source: source)
        symbols.iconImageName = NSExpression(forKeyPath: "icon")
        symbols.iconAllowsOverlap = NSExpression(forConstantValue: true)
        symbols.iconAnchor = NSExpression(forConstantValue: "bottom")
        style.addLayer(symbols) // On top of everything: reports matter more than labels while driving.
    }

    private static func insertBelowLabels(_ layer: MLNStyleLayer, in style: MLNStyle) {
        if let labels = style.layer(withIdentifier: "road-label") {
            style.insertLayer(layer, below: labels)
        } else {
            style.addLayer(layer)
        }
    }
}

/// A teardrop pin in the report's colour with its white icon, like the markers drivers know from other apps.
enum ReportMarkerImage {
    static func make(_ type: ReportType) -> UIImage {
        let width: CGFloat = 34, height: CGFloat = 42
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            let r = width / 2
            let path = UIBezierPath()
            path.addArc(withCenter: CGPoint(x: r, y: r), radius: r - 2, startAngle: .pi * 0.78, endAngle: .pi * 0.22, clockwise: true)
            path.addLine(to: CGPoint(x: r, y: height - 1))
            path.close()

            let cg = context.cgContext
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: UIColor.black.withAlphaComponent(0.3).cgColor)
            let c = type.color
            UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1).setFill()
            path.fill()
            cg.restoreGState()
            UIColor.white.setStroke()
            path.lineWidth = 2
            path.stroke()

            UIImage(named: type.icon.assetName)?
                .withTintColor(.white)
                .draw(in: CGRect(x: r - 9, y: r - 9, width: 18, height: 18))
        }
    }
}
