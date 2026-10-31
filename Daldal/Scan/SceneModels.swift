import RealityKit
import UIKit

/// The bundled 3D models (Kenney's CC0 car, character and castle kits, converted by scripts/models/kenney_to_usdz.py),
/// loaded once and cloned for each use. Characters carry their animations as frame groups ("walk_0" … "walk_7"),
/// shown one at a time like a flip-book.
@MainActor
final class SceneModels {
    static let shared = SceneModels()

    static let cars = ["sedan", "sedan-sports", "suv", "suv-luxury", "taxi", "hatchback-sports", "van", "police"]
    static let trucks = ["truck", "truck-flat", "delivery", "garbage-truck"]
    static let people = ["character-male-a", "character-male-b", "character-male-c", "character-male-d",
                         "character-male-e", "character-male-f", "character-female-a", "character-female-b",
                         "character-female-c", "character-female-d", "character-female-e", "character-female-f"]
    static let road = cars + trucks + people + ["ambulance", "firetruck", "tractor"]
    static let history = people + ["siege-tower", "siege-ram", "siege-catapult", "siege-trebuchet", "siege-ballista",
                                   "wall", "wall-half", "wall-corner", "wall-doorway", "tower-square", "tower-hexagon-base",
                                   "tower-hexagon-roof", "gate", "flag-banner-long", "flag-pennant", "rocks-large",
                                   "tree-large", "ground-hills"]

    private var prototypes: [String: Entity] = [:]

    func preload(_ names: [String]) async {
        for name in names where prototypes[name] == nil {
            if let entity = try? await Entity(named: name, in: .main) {
                prototypes[name] = entity
            }
        }
    }

    var isLoaded: Bool { !prototypes.isEmpty }

    /// A fresh copy, scaled so its longest side along `axis` is `size` metres, standing on y = 0, centred.
    /// `turned` spins it half a turn (Kenney's vehicles face +z; ours drive away from the camera, towards -z).
    func instance(_ name: String, fit size: Float, along axis: Axis = .height, turned: Bool = false) -> Entity? {
        guard let prototype = prototypes[name] else { return nil }
        let model = prototype.clone(recursive: true)
        Self.showFrame(of: model, animation: "walk", frame: 0)
        let bounds = model.visualBounds(relativeTo: nil)
        let extent: Float = switch axis {
        case .height: bounds.extents.y
        case .length: bounds.extents.z
        case .width: bounds.extents.x
        }
        let scale = size / max(extent, 0.001)
        model.scale = SIMD3(repeating: scale)
        model.position = [-bounds.center.x * scale, -bounds.min.y * scale, -bounds.center.z * scale]
        let holder = Entity()
        holder.addChild(model)
        if turned { holder.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0]) }
        holder.components.set(GroundingShadowComponent(castsShadow: true))
        return holder
    }

    enum Axis { case height, length, width }

    /// Picks a stable variant for an object, so the same car keeps its model while it's tracked.
    static func variant(_ names: [String], for id: Int) -> String {
        names[abs(id.hashValue) % names.count]
    }

    /// Shows one frame of a baked animation and hides every other frame group.
    /// Models without that animation keep their first frame of whatever they have.
    static func showFrame(of entity: Entity, animation: String, frame: Int) {
        var groups: [(Entity, String, Int)] = []
        collectFrames(entity, into: &groups)
        guard !groups.isEmpty else { return }
        let animations = Set(groups.map(\.1))
        let chosen = animations.contains(animation) ? animation : (animations.contains("walk") ? "walk" : animations.sorted()[0])
        let count = groups.filter { $0.1 == chosen }.count
        let shown = ((frame % max(count, 1)) + max(count, 1)) % max(count, 1)
        for (group, name, index) in groups {
            group.isEnabled = name == chosen && index == shown
        }
    }

    /// The animations kenney_to_usdz.py bakes (USD prim names, so "-" became "_").
    static let animationNames: Set<String> = ["walk", "idle", "attack_melee_right"]

    private static func collectFrames(_ entity: Entity, into groups: inout [(Entity, String, Int)]) {
        for child in entity.children {
            if let underscore = child.name.lastIndex(of: "_"), let index = Int(child.name[child.name.index(after: underscore)...]),
               animationNames.contains(String(child.name[..<underscore])) {
                groups.append((child, String(child.name[..<underscore]), index))
            } else {
                collectFrames(child, into: &groups)
            }
        }
    }

    /// Tints every material of a model (an army's colours), keeping its texture's shading.
    static func tint(_ entity: Entity, _ color: UIColor) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                if var pbr = material as? PhysicallyBasedMaterial {
                    pbr.baseColor.tint = color
                    return pbr
                }
                return material
            }
            entity.components.set(model)
        }
        for child in entity.children { tint(child, color) }
    }
}
