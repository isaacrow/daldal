import RealityKit
import SwiftUI

/// A landmark's 3D model on the place card: turn it with a finger, pinch to zoom.
struct Landmark3DView: View {
    let model: LandmarkModel
    @Environment(LandmarkModelStore.self) private var store
    @State private var entity: Entity?
    @State private var failed = false
    /// The model loads when asked for: it's heavy, and nothing 3D should start while the card just opens.
    @State private var requested = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ZStack {
                if let entity {
                    RealityView { content in
                        content.camera = .virtual
                        content.add(Self.stage(for: entity))
                    }
                    .realityViewCameraControls(.orbit)
                } else if !requested {
                    Button {
                        requested = true
                    } label: {
                        Label { Text("View the 3D model") } icon: { Icon(.cube, size: 20) }
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("place.model3d.open")
                } else if failed {
                    Text("The 3D model needs an internet connection the first time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom),
                        in: .rect(cornerRadius: Theme.cornerRadius))
            .clipShape(.rect(cornerRadius: Theme.cornerRadius))
            .accessibilityIdentifier("place.model3d")

            HStack(spacing: Theme.Spacing.xs) {
                if model.isHandBuilt {
                    Text("Built from the monument's real proportions.")
                } else {
                    Text("AI model from one photo; hidden sides are estimated.")
                }
                if let photo = model.photoURL, !photo.absoluteString.isEmpty {
                    Link("Photo credit", destination: photo)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .task(id: requested ? model.id : nil) {
            guard requested else { return }
            do {
                let url = try await store.localModel(model)
                entity = try await Entity(contentsOf: url)
            } catch {
                failed = true
            }
        }
    }

    /// The model on a turntable with a key light, centred for the orbit camera, slowly turning.
    private static func stage(for model: Entity) -> Entity {
        let stage = Entity()
        let copy = model.clone(recursive: true)
        let bounds = copy.visualBounds(relativeTo: nil)
        // Big enough to fill the frame from the orbit camera's default distance.
        let scale = 3.4 / max(bounds.extents.x, bounds.extents.y, bounds.extents.z, 0.001)
        copy.scale = SIMD3(repeating: scale)
        copy.position = -bounds.center * scale
        let turntable = Entity()
        turntable.addChild(copy)
        turntable.components.set(SpinComponent())
        stage.addChild(turntable)

        let sun = DirectionalLight()
        sun.light.intensity = 3000
        sun.look(at: .zero, from: [1.5, 2, 2], relativeTo: nil)
        stage.addChild(sun)
        let fill = DirectionalLight()
        fill.light.intensity = 1200
        fill.look(at: .zero, from: [-2, 1, -1], relativeTo: nil)
        stage.addChild(fill)
        if !SpinSystem.registered {
            SpinSystem.registerSystem()
            SpinSystem.registered = true
        }
        return stage
    }
}

/// Slowly turns an entity around its vertical axis.
struct SpinComponent: Component {
    var radiansPerSecond: Float = 0.35
}

struct SpinSystem: System {
    static let query = EntityQuery(where: .has(SpinComponent.self))
    static var registered = false

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let spin = entity.components[SpinComponent.self] else { continue }
            entity.orientation *= simd_quatf(angle: spin.radiansPerSecond * Float(context.deltaTime), axis: [0, 1, 0])
        }
    }
}
