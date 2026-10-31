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
    @State private var model: HeritageScanModel

    init(title: String, summary: String?, events: [HistoryEvent], languageCode: String, voice: VoiceGuide) {
        _model = State(initialValue: HeritageScanModel(title: title, summary: summary, events: events,
                                                       languageCode: languageCode, voice: voice))
    }

    var body: some View {
        ZStack {
            HeritageScanContainer(model: model).ignoresSafeArea()
        }
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) { footer }
        .onDisappear { model.stop() }
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

    @ObservationIgnored private let voice: VoiceGuide
    @ObservationIgnored private weak var arView: ARView?
    @ObservationIgnored private var root: AnchorEntity?
    /// Each army with where it stands and the way it charges.
    @ObservationIgnored private var armies: [(entity: Entity, base: SIMD3<Float>, phase: Float, charge: SIMD3<Float>)] = []
    @ObservationIgnored private var cards: [(entity: Entity, base: Float, phase: Float)] = []
    @ObservationIgnored private var update: (any Cancellable)?
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
        update = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.animate(by: Float(event.deltaTime))
        }
        // Give tracking a moment to settle before building the ring around the camera.
        Task {
            try? await Task.sleep(for: .seconds(0.8))
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
    }

    // MARK: Building blocks

    private func card(named name: String, image: CGImage?, width: Float) -> ModelEntity {
        let aspect = image.map { Float($0.height) / Float($0.width) } ?? 0.6
        var material = UnlitMaterial(color: .white)
        if let image, let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
            material.blending = .transparent(opacity: 1)
        }
        let entity = ModelEntity(mesh: .generatePlane(width: width, height: width * aspect), materials: [material])
        entity.name = name
        entity.generateCollisionShapes(recursive: false)
        return entity
    }

    /// A small table-top scene under each card: two armies facing off, or a walled city under siege.
    private func diorama(for event: HistoryEvent, phase: Float) -> Entity {
        let scene = Entity()
        let sand = SimpleMaterial(color: UIColor(red: 0.80, green: 0.68, blue: 0.48, alpha: 1), roughness: 0.95, isMetallic: false)
        let ground = ModelEntity(mesh: .generateCylinder(height: 0.03, radius: 0.34), materials: [sand])
        scene.addChild(ground)

        let attackers = UIColor(red: 0.72, green: 0.16, blue: 0.14, alpha: 1)
        let defenders = UIColor(red: 0.14, green: 0.36, blue: 0.72, alpha: 1)
        switch event.kind {
        case "siege":
            scene.addChild(walledCity(color: defenders))
            let army = army(color: attackers, rows: 1, columns: 5)
            army.position = [0, 0.015, 0.25]
            scene.addChild(army)
            armies.append((army, army.position, phase, [0, 0, -0.06]))
        case "battle", "uprising":
            for (side, color) in [(Float(-1), attackers), (Float(1), defenders)] {
                let army = army(color: color, rows: 2, columns: 4)
                army.position = [side * 0.17, 0.015, 0]
                army.orientation = simd_quatf(angle: side * .pi / 2, axis: [0, 1, 0])
                scene.addChild(army)
                armies.append((army, army.position, phase, [-side * 0.06, 0, 0]))
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
        let city = Entity()
        let mud = SimpleMaterial(color: UIColor(red: 0.70, green: 0.56, blue: 0.38, alpha: 1), roughness: 0.9, isMetallic: false)
        let size: Float = 0.3
        for (x, z, w, d) in [(Float(0), -size / 2, size, Float(0.02)), (0, size / 2, size, 0.02),
                             (-size / 2, 0, 0.02, size), (size / 2, 0, 0.02, size)] {
            let wall = ModelEntity(mesh: .generateBox(width: w, height: 0.07, depth: d), materials: [mud])
            wall.position = [x, 0.05, z - 0.06]
            city.addChild(wall)
        }
        for x in [-size / 2, size / 2] {
            for z in [-size / 2, size / 2] {
                let tower = ModelEntity(mesh: .generateCylinder(height: 0.11, radius: 0.025), materials: [mud])
                tower.position = [x, 0.07, z - 0.06]
                city.addChild(tower)
            }
        }
        // A dome in the middle and the defenders' flag.
        let dome = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [SimpleMaterial(color: UIColor(red: 0.20, green: 0.55, blue: 0.62, alpha: 1), roughness: 0.4, isMetallic: false)])
        dome.position = [0, 0.03, -0.06]
        city.addChild(dome)
        let flag = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.03, depth: 0.002), materials: [SimpleMaterial(color: color, roughness: 0.6, isMetallic: false)])
        flag.position = [0.03, 0.16, -0.06]
        city.addChild(flag)
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
