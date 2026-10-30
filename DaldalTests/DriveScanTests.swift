import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Daldal

private final class BundleToken {}

/// Runs the real Drive Scan model on a real street photo (public domain, Wikimedia Commons):
/// a busy intersection with about thirty cars, a bus and traffic lights.
@MainActor
struct DriveScanTests {
    @Test func findsCarsOnARealStreet() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "street-cars", withExtension: "jpg"))
        let image = try #require(UIImage(contentsOfFile: url.path())?.cgImage)
        let detector = try #require(ScanDetector(), "the bundled Core ML model didn't load")

        let found = detector.labels(in: image).filter { $0.confidence >= 0.4 }
        let cars = found.filter { $0.label == "car" }
        #expect(cars.count >= 5, "only \(cars.count) cars found; all: \(found.map(\.label))")
        // Every label the app relies on maps to a road-user kind.
        for label in Set(found.map(\.label)) where ["car", "bus", "truck", "traffic light", "person"].contains(label) {
            #expect(ScannedObject.Kind(label: label) != nil, "\(label) isn't mapped")
        }
    }

    @Test func distanceFromSizeIsPhysicallySensible() {
        // A car 1.5 m tall filling 100 px with a 1500 px focal length is 22.5 m away.
        let distance = ScannedObject.Kind.car.realHeight * 1500 / 100
        #expect(abs(distance - 22.5) < 0.01)
    }
}
