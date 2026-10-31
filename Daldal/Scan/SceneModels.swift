import RealityKit
import UIKit

/// The bundled 3D models (Kenney's CC0 car, character and castle kits, converted by scripts/models/kenney_to_usdz.py),
/// loaded once and cloned for each use. Characters carry their animations as frame groups ("walk_0" … "walk_7"),
/// shown one at a time like a flip-book.
@MainActor
final class SceneModels {
    static let shared = SceneModels()

    /// Plain body shapes only (no taxi signs or light bars): Drive Scan draws every vehicle in one matte colour.
    static let cars = ["sedan", "sedan-sports", "suv", "suv-luxury", "hatchback-sports", "van"]
    static let trucks = ["truck", "truck-flat", "delivery", "garbage-truck"]
    static let people = ["character-male-a", "character-male-b", "character-male-c", "character-male-d",
                         "character-male-e", "character-male-f", "character-female-a", "character-female-b",
                         "character-female-c", "character-female-d", "character-female-e", "character-female-f"]
    static let road = cars + trucks + people + ["ambulance", "firetruck", "tractor"]
    /// Three soldier variants are plenty at table-top size, and each animated figure is heavy in memory.
    static let soldiers = Array(people.prefix(3))
    static let history = soldiers + ["siege-tower", "siege-ram", "siege-catapult", "siege-trebuchet", "siege-ballista",
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
    static let animationNames: Set<String> = ["walk", "idle", "attack_melee_right", "sword_slash", "run", "idle_sword", "gallop"]

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

    /// Replaces every material with one matte "clay" colour: the calm, uniform look of a car's driving display,
    /// where shape tells you what something is and colour is kept for warnings.
    static func clay(_ entity: Entity, _ color: UIColor, roughness: Float = 0.55, clearcoat: Float = 0) {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = 0.0
        if clearcoat > 0 {
            material.clearcoat = .init(floatLiteral: clearcoat)
            material.clearcoatRoughness = 0.1
        }
        func apply(_ e: Entity) {
            if var model = e.components[ModelComponent.self] {
                model.materials = Array(repeating: material, count: max(model.materials.count, 1))
                e.components.set(model)
            }
            for child in e.children { apply(child) }
        }
        apply(entity)
    }

    static let clayVehicle = UIColor(white: 0.74, alpha: 1)
    static let clayPerson = UIColor(white: 0.93, alpha: 1)
    static let clayEgo = UIColor(white: 0.97, alpha: 1)

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

    /// A date palm: a ringed, slightly leaning trunk and a crown of drooping fronds.
    static func datePalm(seed: Int) -> Entity {
        var bark = PhysicallyBasedMaterial()
        bark.baseColor = .init(tint: UIColor(red: 0.45, green: 0.35, blue: 0.24, alpha: 1))
        bark.roughness = 0.95
        var frond = PhysicallyBasedMaterial()
        frond.baseColor = .init(tint: UIColor(red: 0.30, green: 0.48, blue: 0.20, alpha: 1))
        frond.roughness = 0.8
        let palm = Entity()
        let lean = Float(seed % 3 - 1) * 0.04
        let rings = 9
        for r in 0..<rings {
            let ring = ModelEntity(mesh: .generateCylinder(height: 0.62, radius: 0.2 - Float(r) * 0.006), materials: [bark])
            ring.position = [lean * Float(r) * 0.6, 0.31 + Float(r) * 0.6, 0]
            palm.addChild(ring)
        }
        let top = SIMD3<Float>(lean * Float(rings) * 0.6, Float(rings) * 0.6 + 0.1, 0)
        let fronds = 9
        for f in 0..<fronds {
            let yaw = Float(f) / Float(fronds) * 2 * .pi + Float(seed) * 0.4
            let leaf = ModelEntity(mesh: .generateBox(width: 0.45, height: 0.03, depth: 2.6, cornerRadius: 0.012), materials: [frond])
            leaf.position = [0, 0, -1.2]
            let pivot = Entity()
            pivot.position = top
            pivot.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -0.45 - Float(f % 3) * 0.12, axis: [1, 0, 0])
            pivot.addChild(leaf)
            palm.addChild(pivot)
        }
        palm.components.set(GroundingShadowComponent(castsShadow: true))
        return palm
    }
}
