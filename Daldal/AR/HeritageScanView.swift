import ARKit
import AVFoundation
import Combine
import RealityKit
import SwiftUI

/// Heritage Scan: at a monument or old city, a ring of floating 3D story cards appears around you, one for the
/// place itself and one for each battle or siege that happened nearby, each standing over a small animated
/// diorama of what happened. Tap a card to hear it.
struct HeritageScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LandmarkModelStore.self) private var landmarks
    @State private var model: HeritageScanModel
    private let landmark: LandmarkModel?

    init(title: String, summary: String?, events: [HistoryEvent], languageCode: String, voice: VoiceGuide,
         model landmark: LandmarkModel? = nil) {
        _model = State(initialValue: HeritageScanModel(title: title, summary: summary, events: events,
                                                       languageCode: languageCode, voice: voice))
        self.landmark = landmark
    }

    var body: some View {
        ZStack {
            HeritageScanContainer(model: model).ignoresSafeArea()
            HandIndicator(hand: model.hand)
        }
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) { footer }
        .onDisappear { model.stop() }
        .task {
            // The monument itself, on a pedestal in front of you, once its model has downloaded.
            guard let landmark, let url = try? await landmarks.localModel(landmark),
                  let entity = try? await Entity(contentsOf: url) else { return }
            model.showLandmark(entity)
        }
        .statusBarHidden()
        .accessibilityIdentifier("history.screen")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline)
                Text(model.events.isEmpty ? "No recorded battles nearby" : "\(model.events.count) moments in history")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerRadius))
            Spacer()
            GlassIconButton(icon: .close, label: "Close") { dismiss() }
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    private var footer: some View {
        VStack(spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.m) {
                Text(model.message)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Place here") { model.placeInFront() }
                    .buttonStyle(.glass)
                    .disabled(!model.isRunning)
            }
            if let playing = model.speaking, let url = playing.wikipediaURL(languageCode: model.languageCode) {
                Link(destination: url) {
                    Text("Wikipedia, CC BY-SA").font(.caption)
                }
            }
        }
        .padding(Theme.Spacing.l)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerRadius))
        .padding(Theme.Spacing.l)
    }
}

@Observable
final class HeritageScanModel {
    let title: String
    let summary: String?
    let events: [HistoryEvent]
    let languageCode: String
    private(set) var isRunning = false
    private(set) var unsupported = false
    /// The event being read aloud, for its credit link.
    private(set) var speaking: HistoryEvent?

    var message: LocalizedStringKey {
        if unsupported { return "This iPhone doesn't support AR." }
        if !isRunning { return "Starting the camera…" }
        return "Turn around you and tap a card to hear its story."
    }

    /// The visitor's hand: pinch and move sideways to turn the ring of stories, up and down to resize the monument.
    private(set) var hand: HandControl.Hand?
    @ObservationIgnored private let hands = HandControl()
    @ObservationIgnored private let voice: VoiceGuide
    @ObservationIgnored private weak var arView: ARView?
    @ObservationIgnored private var root: AnchorEntity?
    /// Each army with where it stands and the way it charges.
    @ObservationIgnored private var armies: [(entity: Entity, base: SIMD3<Float>, phase: Float, charge: SIMD3<Float>)] = []
    @ObservationIgnored private var cards: [(entity: Entity, base: Float, phase: Float)] = []
    /// Animated soldiers: which baked animation each plays, and its offset so they don't move in lockstep.
    @ObservationIgnored private var fighters: [(entity: Entity, animation: String, offset: Int)] = []
    @ObservationIgnored private var update: (any Cancellable)?
    /// The monument's 3D model, shown turning on a pedestal under its card.
    @ObservationIgnored private var landmark: Entity?
    @ObservationIgnored private var clock: Float = 0

    init(title: String, summary: String?, events: [HistoryEvent], languageCode: String, voice: VoiceGuide) {
        self.title = title
        self.summary = summary
        self.events = events
        self.languageCode = languageCode
        self.voice = voice
    }

    // MARK: Lifecycle

    func start(in view: ARView) {
        arView = view
        guard ARWorldTrackingConfiguration.isSupported else { unsupported = true; return }
        let config = ARWorldTrackingConfiguration()
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        view.session.run(config)
        hands.attach(to: view.session)
        hands.onHand = { [weak self] hand in self?.hand = hand }
        hands.onDrag = { [weak self] delta in self?.handDrag(delta) }
        update = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.animate(by: Float(event.deltaTime))
        }
        // Give tracking a moment to settle before building the ring around the camera.
        Task {
            async let models: Void = SceneModels.shared.preload(SceneModels.history)
            try? await Task.sleep(for: .seconds(0.8))
            await models
            placeInFront()
            isRunning = true
        }
    }

    func stop() {
        update?.cancel()
        update = nil
        arView?.session.pause()
        voice.stopSpeaking()
    }

    func tapped(at point: CGPoint) {
        guard let arView, var entity = arView.entity(at: point) else { return }
        while !entity.name.hasPrefix("card:"), let parent = entity.parent { entity = parent }
        let id = entity.name.dropFirst("card:".count)
        if id == "site" {
            speaking = nil
            voice.announce([title, summary].compactMap(\.self).joined(separator: ". "), interrupt: true)
        } else if let event = events.first(where: { $0.id == id }) {
            speaking = event
            voice.announce("\(event.yearText). \(event.name(languageCode: languageCode)). \(event.summary(languageCode: languageCode) ?? "")",
                           interrupt: true)
        } else {
            return
        }
        // A little bounce on the card that's talking.
        let original = entity.scale
        entity.scale = original * 1.08
        Task {
            try? await Task.sleep(for: .seconds(0.18))
            entity.scale = original
        }
    }

    /// Builds (or rebuilds) the ring around the camera: the place in front, its history arcing left to right.
    func placeInFront() {
        guard let arView else { return }
        let camera = arView.cameraTransform
        let forward = -camera.matrix.columns.2
        let yaw = atan2(-forward.x, -forward.z)
        let anchor = AnchorEntity(world: camera.translation)
        anchor.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        armies = []
        cards = []
        fighters = []

        let siteCard = card(named: "card:site", image: Self.render(SiteCardFace(title: title, summary: summary,
                                                                                    languageCode: languageCode)),
                            width: 1.0)
        siteCard.position = [0, 0.35, -2.2]
        anchor.addChild(siteCard)
        cards.append((siteCard, 0.35, 0))

        // Up to seven events on an arc from left to right, oldest first, with their diorama below.
        let spread: Float = events.count > 1 ? min(.pi * 0.85, Float(events.count - 1) * 0.42) : 0
        for (index, event) in events.enumerated() {
            let angle = events.count > 1 ? -spread / 2 + spread * Float(index) / Float(events.count - 1) : 0
            let radius: Float = 2.7
            let holder = Entity()
            holder.position = [sin(angle) * radius, 0, -cos(angle) * radius]
            holder.orientation = simd_quatf(angle: -angle, axis: [0, 1, 0])

            let face = Self.render(EventCardFace(event: event, languageCode: languageCode))
            let eventCard = card(named: "card:\(event.id)", image: face, width: 0.75)
            eventCard.position = [0, -0.25, 0]
            holder.addChild(eventCard)
            cards.append((eventCard, -0.25, Float(index) * 0.9))

            let diorama = diorama(for: event, phase: Float(index))
            diorama.position = [0, -0.95, 0.15]
            holder.addChild(diorama)
            anchor.addChild(holder)
        }

        if let root { arView.scene.removeAnchor(root) }
        arView.scene.addAnchor(anchor)
        root = anchor
        if let landmark { addLandmark(landmark, to: anchor) }
    }

    private func handDrag(_ delta: CGVector) {
        guard let root else { return }
        root.orientation = simd_quatf(angle: Float(delta.dx) * .pi * 1.5, axis: [0, 1, 0]) * root.orientation
        if let landmark = root.findEntity(named: "landmark") {
            let next = min(max(landmark.scale.x * (1 - Float(delta.dy) * 1.8), 0.4), 3)
            landmark.scale = SIMD3(repeating: next)
        }
    }

    func showLandmark(_ entity: Entity) {
        landmark = entity
        if let root { addLandmark(entity, to: root) }
    }

    private func addLandmark(_ entity: Entity, to anchor: Entity) {
        anchor.findEntity(named: "landmark")?.removeFromParent()
        let holder = Entity()
        holder.name = "landmark"
        holder.position = [0, -0.95, -2.0]
        let stone = SimpleMaterial(color: UIColor(white: 0.85, alpha: 1), roughness: 0.7, isMetallic: false)
        let pedestal = ModelEntity(mesh: .generateCylinder(height: 0.05, radius: 0.4), materials: [stone])
        holder.addChild(pedestal)
        let copy = entity.clone(recursive: true)
        let bounds = copy.visualBounds(relativeTo: nil)
        let scale = 0.55 / max(bounds.extents.y, bounds.extents.x * 0.6, 0.001)
        copy.scale = SIMD3(repeating: scale)
        copy.position = [-bounds.center.x * scale, 0.025 - bounds.min.y * scale, -bounds.center.z * scale]
        let turntable = Entity()
        turntable.name = "landmark-turntable"
        turntable.addChild(copy)
        holder.addChild(turntable)
        anchor.addChild(holder)
    }

    // MARK: Building blocks

    private func card(named name: String, image: CGImage?, width: Float) -> ModelEntity {
        let aspect = image.map { Float($0.height) / Float($0.width) } ?? 0.6
        var material = UnlitMaterial(color: .white)
        if let image, let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
        }
        let entity = ModelEntity(mesh: .generatePlane(width: width, height: width * aspect), materials: [material])
        entity.name = name
        entity.generateCollisionShapes(recursive: false)
        return entity
    }

    /// A small table-top scene under each card: two armies fighting, or a walled city under siege, built from
    /// the bundled models (soldiers with sword swings, siege towers, rams, trebuchets, castle walls).
    private func diorama(for event: HistoryEvent, phase: Float) -> Entity {
        let scene = Entity()
        let sand = SimpleMaterial(color: UIColor(red: 0.80, green: 0.68, blue: 0.48, alpha: 1), roughness: 0.95, isMetallic: false)
        let ground = ModelEntity(mesh: .generateCylinder(height: 0.03, radius: 0.42), materials: [sand])
        scene.addChild(ground)
        let library = SceneModels.shared
        // A few rocks and a tree at the edge, so it reads as a landscape.
        for (k, name) in ["rocks-large", "tree-large", "rocks-large"].enumerated() {
            guard let prop = library.instance(name, fit: name == "tree-large" ? 0.16 : 0.05) else { continue }
            let angle = Float(k) * 2.1 + phase
            prop.position = [sin(angle) * 0.36, 0.015, cos(angle) * 0.36]
            scene.addChild(prop)
        }

        let attackers = UIColor(red: 1.0, green: 0.55, blue: 0.5, alpha: 1)
        let defenders = UIColor(red: 0.55, green: 0.68, blue: 1.0, alpha: 1)
        switch event.kind {
        case "siege":
            scene.addChild(walledCity(color: defenders))
            let troop = soldiers(color: attackers, rows: 2, columns: 5, animation: "attack_melee_right", phase: phase)
                ?? army(color: attackers, rows: 1, columns: 5)
            troop.position = [0, 0.015, 0.27]
            scene.addChild(troop)
            armies.append((troop, troop.position, phase, [0, 0, -0.05]))
            let engines: [(String, Float, Float, Float)] = [("siege-tower", -0.2, 0.18, 0.2), ("siege-ram", 0, 0.14, 0.09),
                                                            ("siege-trebuchet", 0.24, 0.3, 0.17)]
            for (name, x, z, size) in engines {
                guard let engine = library.instance(name, fit: size, turned: true) else { continue }
                engine.position = [x, 0.015, z]
                scene.addChild(engine)
            }
        case "battle", "uprising":
            let animation = event.kind == "battle" ? "attack_melee_right" : "walk"
            for (side, color) in [(Float(-1), attackers), (Float(1), defenders)] {
                let troop = soldiers(color: color, rows: 2, columns: 4, animation: animation, phase: phase + side)
                    ?? army(color: color, rows: 2, columns: 4)
                troop.position = [side * 0.17, 0.015, 0]
                troop.orientation = simd_quatf(angle: side * .pi / 2, axis: [0, 1, 0])
                scene.addChild(troop)
                armies.append((troop, troop.position, phase, [-side * 0.06, 0, 0]))
                if event.kind == "battle", let engine = library.instance(side < 0 ? "siege-catapult" : "siege-ballista", fit: 0.09) {
                    engine.position = [side * 0.33, 0.015, -0.12]
                    engine.orientation = simd_quatf(angle: side * .pi / 2 + .pi, axis: [0, 1, 0])
                    scene.addChild(engine)
                }
            }
        default:
            // Remembrance, not re-enactment: a simple stone marker.
            let stone = SimpleMaterial(color: UIColor(white: 0.82, alpha: 1), roughness: 0.8, isMetallic: false)
            let obelisk = ModelEntity(mesh: .generateBox(width: 0.06, height: 0.3, depth: 0.06, cornerRadius: 0.01), materials: [stone])
            obelisk.position.y = 0.165
            scene.addChild(obelisk)
        }
        return scene
    }

    /// Ranks of soldiers in an army's colours, facing -z, each playing an animation slightly out of step.
    private func soldiers(color: UIColor, rows: Int, columns: Int, animation: String, phase: Float) -> Entity? {
        let library = SceneModels.shared
        let army = Entity()
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column + Int(phase * 3)
                guard let soldier = library.instance(SceneModels.people[abs(index) % SceneModels.people.count], fit: 0.1) else {
                    return nil
                }
                SceneModels.tint(soldier, color)
                soldier.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0]) // The models face +z.
                soldier.position = [(Float(column) - Float(columns - 1) / 2) * 0.06, 0, Float(row) * 0.065]
                army.addChild(soldier)
                fighters.append((soldier, animation, index * 3))
            }
        }
        if let banner = library.instance("flag-banner-long", fit: 0.18) {
            SceneModels.tint(banner, color)
            banner.position = [0, 0, Float(rows) * 0.065]
            army.addChild(banner)
        }
        return army
    }

    private func army(color: UIColor, rows: Int, columns: Int) -> Entity {
        let army = Entity()
        let cloth = SimpleMaterial(color: color, roughness: 0.6, isMetallic: false)
        let skin = SimpleMaterial(color: UIColor(red: 0.85, green: 0.68, blue: 0.52, alpha: 1), roughness: 0.7, isMetallic: false)
        let steel = SimpleMaterial(color: UIColor(white: 0.75, alpha: 1), roughness: 0.3, isMetallic: true)
        let body = MeshResource.generateBox(width: 0.026, height: 0.05, depth: 0.018, cornerRadius: 0.008)
        let head = MeshResource.generateSphere(radius: 0.011)
        let spear = MeshResource.generateBox(width: 0.003, height: 0.1, depth: 0.003)
        let shield = MeshResource.generateCylinder(height: 0.004, radius: 0.014)
        for row in 0..<rows {
            for column in 0..<columns {
                let soldier = Entity()
                soldier.position = [(Float(column) - Float(columns - 1) / 2) * 0.05, 0, Float(row) * 0.05]
                let torso = ModelEntity(mesh: body, materials: [cloth])
                torso.position.y = 0.025
                let face = ModelEntity(mesh: head, materials: [skin])
                face.position.y = 0.062
                let pike = ModelEntity(mesh: spear, materials: [steel])
                pike.position = [0.017, 0.055, 0]
                let guardPlate = ModelEntity(mesh: shield, materials: [cloth])
                guardPlate.position = [-0.016, 0.03, -0.004]
                guardPlate.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
                for part in [torso, face, pike, guardPlate] { soldier.addChild(part) }
                army.addChild(soldier)
            }
        }
        // A banner over the front rank.
        let pole = ModelEntity(mesh: .generateBox(width: 0.004, height: 0.16, depth: 0.004), materials: [steel])
        pole.position = [0, 0.08, -0.03]
        let flag = ModelEntity(mesh: .generateBox(width: 0.06, height: 0.035, depth: 0.002), materials: [cloth])
        flag.position = [0.032, 0.14, -0.03]
        army.addChild(pole)
        army.addChild(flag)
        return army
    }

    private func walledCity(color: UIColor) -> Entity {
        let library = SceneModels.shared
        let city = Entity()
        let size: Float = 0.3
        let module: Float = 0.075
        let modules = Int(size / module)
        var built = true
        // Four walls of castle-kit modules (a gate facing the attackers), towers at the corners.
        for side in 0..<4 {
            let yaw = Float(side) * .pi / 2
            for k in 0..<modules {
                let name = side == 0 && k == modules / 2 ? "gate" : "wall"
                guard let piece = library.instance(name, fit: module, along: .width) else { built = false; break }
                let along = (Float(k) - Float(modules - 1) / 2) * module
                let local = SIMD3<Float>(along, 0.015, size / 2)
                piece.position = simd_quatf(angle: yaw, axis: [0, 1, 0]).act(local) + [0, 0, -0.06]
                piece.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
                city.addChild(piece)
            }
        }
        for x in [-size / 2, size / 2] {
            for z in [-size / 2, size / 2] {
                guard let tower = library.instance("tower-square", fit: module * 1.3, along: .width) else { built = false; continue }
                tower.position = [x, 0.015, z - 0.06]
                city.addChild(tower)
                if let roof = library.instance("tower-hexagon-roof", fit: module * 1.1, along: .width) {
                    roof.position = [x, 0.015 + tower.visualBounds(relativeTo: city).extents.y, z - 0.06]
                    city.addChild(roof)
                }
            }
        }
        if !built {
            city.children.removeAll()
            let mud = SimpleMaterial(color: UIColor(red: 0.70, green: 0.56, blue: 0.38, alpha: 1), roughness: 0.9, isMetallic: false)
            for (x, z, w, d) in [(Float(0), -size / 2, size, Float(0.02)), (0, size / 2, size, 0.02),
                                 (-size / 2, 0, 0.02, size), (size / 2, 0, 0.02, size)] {
                let wall = ModelEntity(mesh: .generateBox(width: w, height: 0.07, depth: d), materials: [mud])
                wall.position = [x, 0.05, z - 0.06]
                city.addChild(wall)
            }
        }
        // A turquoise dome in the middle, like Iraq's old mosques, and the defenders' flag.
        let dome = ModelEntity(mesh: .generateSphere(radius: 0.06), materials: [SimpleMaterial(color: UIColor(red: 0.20, green: 0.55, blue: 0.62, alpha: 1), roughness: 0.4, isMetallic: false)])
        dome.position = [0, 0.04, -0.06]
        city.addChild(dome)
        if let flag = library.instance("flag-pennant", fit: 0.14) {
            SceneModels.tint(flag, color)
            flag.position = [0.04, 0.05, -0.06]
            city.addChild(flag)
        }
        return city
    }

    // MARK: Animation

    private func animate(by delta: Float) {
        clock += delta
        // Armies advance and fall back; cards float gently.
        for army in armies {
            let surge = (sin(clock * 1.4 + army.phase) + 1) / 2
            army.entity.position = army.base + army.charge * surge
        }
        for card in cards {
            card.entity.position.y = card.base + sin(clock * 0.9 + card.phase) * 0.015
        }
        if let turntable = root?.findEntity(named: "landmark-turntable") {
            turntable.orientation = simd_quatf(angle: clock * 0.3, axis: [0, 1, 0])
        }
        let frame = Int(clock * 9)
        for fighter in fighters {
            SceneModels.showFrame(of: fighter.entity, animation: fighter.animation, frame: frame + fighter.offset)
        }
    }

    // MARK: Card faces

    private static func render(_ view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view.environment(\.layoutDirection, AppLanguage.code == "ar" ? .rightToLeft : .leftToRight))
        renderer.scale = 2
        return renderer.cgImage
    }
}

private struct SiteCardFace: View {
    let title: String
    let summary: String?
    let languageCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 34, weight: .bold))
            if let summary {
                Text(summary).font(.system(size: 19)).lineLimit(7).opacity(0.9)
            }
            Text("Tap to listen").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(width: 620, alignment: .leading)
        .background(LinearGradient(colors: [Color(white: 0.12).opacity(0.92), Color(white: 0.04).opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom),
                    in: .rect(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(Theme.accent.opacity(0.7), lineWidth: 3))
    }
}

private struct EventCardFace: View {
    let event: HistoryEvent
    let languageCode: String

    private var kindLabel: LocalizedStringKey {
        switch event.kind {
        case "siege": "Siege"
        case "battle": "Battle"
        case "uprising": "Uprising"
        case "massacre": "Remembrance"
        default: "Event"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(event.yearText).font(.system(size: 36, weight: .heavy).monospacedDigit()).foregroundStyle(Theme.accent)
                Spacer()
                Text(kindLabel).font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.white.opacity(0.14), in: .capsule)
            }
            Text(event.name(languageCode: languageCode)).font(.system(size: 26, weight: .bold)).lineLimit(2)
            if let summary = event.summary(languageCode: languageCode) {
                Text(summary).font(.system(size: 17)).lineLimit(6).opacity(0.88)
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(width: 480, alignment: .leading)
        .background(Color(red: 0.10, green: 0.08, blue: 0.06).opacity(0.9), in: .rect(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color(red: 0.85, green: 0.66, blue: 0.35).opacity(0.8), lineWidth: 3))
    }
}

private struct HeritageScanContainer: UIViewRepresentable {
    let model: HeritageScanModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        model.start(in: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject {
        let model: HeritageScanModel
        init(model: HeritageScanModel) { self.model = model }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            model.tapped(at: recognizer.location(in: recognizer.view))
        }
    }
}
