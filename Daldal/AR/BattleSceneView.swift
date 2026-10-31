import ARKit
import CoreLocation
import Combine
import RealityKit
import SwiftUI

/// The Battle of Karbala (10 Muharram 61 AH / 680 CE) as a table-top 3D scene placed on the ground in AR:
/// the Euphrates and its palms, Imam Husayn's camp, the riderless white horse, the companions in front of the
/// tents, and the Umayyad army of Umar ibn Sa'd in ranks and cavalry blocks, cutting the camp off from the river.
/// A narrator walks through the day step by step, lighting up each part of the field.
struct BattleSceneView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: BattleSceneModel

    init(languageCode: String, voice: VoiceGuide) {
        _model = State(initialValue: BattleSceneModel(languageCode: languageCode, voice: voice))
    }

    var body: some View {
        ZStack {
            BattleSceneContainer(model: model).ignoresSafeArea()
            HandIndicator(hand: model.hand)
        }
        .overlay(alignment: .top) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Battle of Karbala").font(.headline)
                    Text("10 Muharram 61 AH · 680 CE").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerRadius))
                Spacer()
                GlassIconButton(icon: .close, label: "Close") { dismiss() }
            }
            .padding(.horizontal, Theme.Spacing.l)
        }
        .overlay(alignment: .bottom) { narration }
        .onDisappear { model.stop() }
        .statusBarHidden()
        .accessibilityIdentifier("battle.screen")
    }

    @ViewBuilder private var narration: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if model.unsupported {
                Text("This iPhone doesn't support AR.")
            } else if !model.isPlaced {
                Text(model.isLoading ? "Preparing the battlefield…" : "Point at the ground and tap to place the battlefield.")
            } else {
                Text(model.step.text(model.languageCode))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Previous") { model.go(by: -1) }
                        .buttonStyle(.glass)
                        .disabled(model.stepIndex == 0)
                    Spacer()
                    Text("\(model.stepIndex + 1) / \(BattleSceneModel.steps.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Next") { model.go(by: 1) }
                        .buttonStyle(.glassProminent)
                        .disabled(model.stepIndex == BattleSceneModel.steps.count - 1)
                }
                Text(model.credits)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerRadius))
        .padding(Theme.Spacing.l)
    }
}

@Observable
final class BattleSceneModel {
    /// Where the battle was fought (Wikidata Q626058); the scene is offered within 2 km of it.
    static let site = CLLocation(latitude: 32.61528, longitude: 44.03139)

    static func isNear(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: site) < 2_000
    }

    /// One stop on the narrated walk through the day: what's said and where the light falls (scene metres).
    struct Step {
        let en: String
        let ar: String
        let focus: SIMD3<Float>
        let radius: Float

        func text(_ languageCode: String) -> String { languageCode == "ar" ? ar : en }
    }

    static let steps: [Step] = [
        Step(en: "In Muharram 61 AH (680 CE), Imam Husayn ibn Ali camped here at Karbala, by the Euphrates, with his family and about seventy-two companions.",
             ar: "في محرم سنة 61 للهجرة (680 م) نزل الإمام الحسين بن علي هنا في كربلاء قرب الفرات، ومعه أهل بيته ونحو اثنين وسبعين من أصحابه.",
             focus: [-0.75, 0, 0.2], radius: 0.55),
        Step(en: "The Umayyad army under Umar ibn Sa'd, many thousands strong, drew up in ranks and cavalry facing the small camp.",
             ar: "واصطفّ الجيش الأموي بقيادة عمر بن سعد، بآلاف المقاتلين من المشاة والفرسان، في مواجهة المخيّم الصغير.",
             focus: [0.55, 0, -0.1], radius: 0.8),
        Step(en: "From the seventh of Muharram the army held the riverbank, cutting the camp off from the water of the Euphrates in the desert heat.",
             ar: "ومنذ السابع من محرم سيطر الجيش على ضفة النهر، فقطع الماء عن المخيّم في حرّ الصحراء.",
             focus: [-0.15, 0, -0.85], radius: 0.55),
        Step(en: "On the tenth, the day of Ashura, Husayn's companions stood before the tents and fell one by one. Al-Abbas was killed trying to bring water from the river.",
             ar: "وفي اليوم العاشر، يوم عاشوراء، وقف أصحاب الحسين أمام الخيام واستُشهدوا واحداً بعد واحد، واستُشهد العباس وهو يحاول جلب الماء من النهر.",
             focus: [-0.35, 0, 0.2], radius: 0.45),
        Step(en: "Imam Husayn was martyred that afternoon. His horse returned to the camp without its rider; the women and children were taken captive to Kufa and Damascus.",
             ar: "واستُشهد الإمام الحسين عصر ذلك اليوم، وعاد جواده إلى المخيّم بلا فارس، وسيقت النساء والأطفال أسرى إلى الكوفة ثم الشام.",
             focus: [-0.55, 0, 0.45], radius: 0.35),
        Step(en: "His shrine now stands on this ground, and that of Al-Abbas nearby. Millions walk here every year for Ashura and Arbaeen.",
             ar: "ويقوم مرقده اليوم على هذه الأرض، ومرقد العباس بالقرب منه، ويقصدهما الملايين كل عام في عاشوراء والأربعين.",
             focus: [0, 0, 0], radius: 1.4),
    ]

    let languageCode: String
    private(set) var isLoading = true
    private(set) var isPlaced = false
    private(set) var unsupported = false
    private(set) var stepIndex = 0
    /// The visitor's hand in front of the camera: pinch and move to turn and resize the battlefield.
    private(set) var hand: HandControl.Hand?
    @ObservationIgnored private let hands = HandControl()
    var step: Step { Self.steps[stepIndex] }

    var credits: String {
        var parts = [String(localized: "Models: Quaternius (CC0), camel by Poly by Google (CC BY 3.0).")]
        if Self.painting(1) != nil || Self.painting(2) != nil {
            parts.append(String(localized: "Paintings shown with the artists' permission."))
        }
        return parts.joined(separator: " ")
    }

    @ObservationIgnored private let voice: VoiceGuide
    @ObservationIgnored private weak var arView: ARView?
    @ObservationIgnored private var root: AnchorEntity?
    @ObservationIgnored private var scene: Entity?
    @ObservationIgnored private var focusRing: Entity?
    @ObservationIgnored private var animated: [(groups: [String: [Entity]], animation: String, offset: Int, shown: Entity?)] = []
    @ObservationIgnored private var movers: [(entity: Entity, base: SIMD3<Float>, swing: SIMD3<Float>, phase: Float)] = []
    @ObservationIgnored private var river: [ModelEntity] = []
    @ObservationIgnored private var update: (any Cancellable)?
    @ObservationIgnored private var clock: Float = 0
    @ObservationIgnored private var lastFrame = -1

    init(languageCode: String, voice: VoiceGuide) {
        self.languageCode = languageCode
        self.voice = voice
    }

    // MARK: Lifecycle

    func start(in view: ARView) {
        arView = view
        guard ARWorldTrackingConfiguration.isSupported else { unsupported = true; isLoading = false; return }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        view.session.run(config)
        hands.attach(to: view.session)
        hands.onHand = { [weak self] hand in self?.hand = hand }
        hands.onDrag = { [weak self] delta in self?.handDrag(delta) }
        let coaching = ARCoachingOverlayView()
        coaching.session = view.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(coaching)
        update = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.animate(by: Float(event.deltaTime))
        }
        Task {
            await SceneModels.shared.preload(["warrior-hooded", "horse-white", "horse-brown", "camel", "tent", "spear",
                                              "flag-banner-long"])
            scene = build()
            isLoading = false
        }
    }

    func stop() {
        update?.cancel()
        update = nil
        arView?.session.pause()
        voice.stopSpeaking()
    }

    /// Places the battlefield where the tap meets the ground (or a detected floor/table).
    func tapped(at point: CGPoint) {
        guard let arView, let scene else { return }
        guard let hit = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first else { return }
        let anchor = AnchorEntity(world: hit.worldTransform)
        // Face the camera with the camp on the left and the river at the back, as in the old battle paintings.
        let camera = arView.cameraTransform.translation
        let position = hit.worldTransform.columns.3
        let yaw = atan2(camera.x - position.x, camera.z - position.z)
        anchor.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        scene.removeFromParent()
        anchor.addChild(scene)
        if let root { arView.scene.removeAnchor(root) }
        arView.scene.addAnchor(anchor)
        root = anchor
        if !isPlaced {
            isPlaced = true
            go(by: 0)
        }
    }

    /// Sideways turns the field around its centre; up and down makes it bigger or smaller.
    private func handDrag(_ delta: CGVector) {
        guard let scene, isPlaced else { return }
        scene.orientation = simd_quatf(angle: Float(delta.dx) * .pi * 1.5, axis: [0, 1, 0]) * scene.orientation
        let next = min(max(scene.scale.x * (1 - Float(delta.dy) * 1.8), 0.25), 4)
        scene.scale = SIMD3(repeating: next)
    }

    func pinched(_ scale: CGFloat) {
        guard let scene else { return }
        let next = min(max(scene.scale.x * Float(scale), 0.25), 4)
        scene.scale = SIMD3(repeating: next)
    }

    func go(by delta: Int) {
        stepIndex = min(max(stepIndex + delta, 0), Self.steps.count - 1)
        focusRing?.position = step.focus + [0, 0.025, 0]
        focusRing?.scale = SIMD3(step.radius, 1, step.radius)
        voice.announce(step.text(languageCode), interrupt: true)
    }

    // MARK: Building the field

    private func build() -> Entity {
        let field = Entity()
        let library = SceneModels.shared

        // Desert: a wide sand table with low dunes.
        var sand = PhysicallyBasedMaterial()
        sand.baseColor = .init(tint: UIColor(red: 0.84, green: 0.72, blue: 0.52, alpha: 1))
        sand.roughness = 1.0
        let ground = ModelEntity(mesh: .generateBox(width: 3.0, height: 0.04, depth: 2.3, cornerRadius: 0.02), materials: [sand])
        ground.position.y = -0.02
        field.addChild(ground)
        for k in 0..<7 {
            let dune = ModelEntity(mesh: .generateSphere(radius: 0.25), materials: [sand])
            dune.scale = [1.4, 0.18, 0.8]
            dune.position = [-1.3 + Float(k) * 0.45, 0, 1.0 - Float(k % 2) * 0.12]
            field.addChild(dune)
        }

        // The Euphrates along the back, with date palms on the far bank.
        var water = PhysicallyBasedMaterial()
        water.baseColor = .init(tint: UIColor(red: 0.16, green: 0.42, blue: 0.55, alpha: 1))
        water.roughness = 0.05
        water.metallic = 0.3
        for k in 0..<6 {
            let stretch = ModelEntity(mesh: .generateBox(width: 0.52, height: 0.012, depth: 0.32, cornerRadius: 0.004), materials: [water])
            stretch.position = [-1.25 + Float(k) * 0.5, 0.004, -1.0 + sin(Float(k)) * 0.04]
            field.addChild(stretch)
            river.append(stretch)
        }
        for k in 0..<10 {
            let palm = SceneModels.datePalm(seed: k)
            palm.scale = SIMD3(repeating: 0.035)
            palm.position = [-1.4 + Float(k) * 0.3, 0, -1.12 - Float(k % 2) * 0.03]
            field.addChild(palm)
        }

        // Imam Husayn's camp: a horseshoe of tents on the left, open towards the field.
        let tentColours = [UIColor(white: 0.95, alpha: 1), UIColor(red: 0.93, green: 0.88, blue: 0.78, alpha: 1)]
        for k in 0..<16 {
            let angle = Float(k) / 16 * .pi * 1.5 + .pi * 0.75
            guard let tent = library.instance("tent", fit: 0.09) else { continue }
            SceneModels.tint(tent, tentColours[k % 2])
            tent.position = [-0.85 + cos(angle) * 0.32, 0, 0.25 + sin(angle) * 0.25]
            tent.orientation = simd_quatf(angle: -angle, axis: [0, 1, 0])
            field.addChild(tent)
        }
        for k in 0..<4 {
            guard let camel = library.instance("camel", fit: 0.06) else { continue }
            camel.position = [-1.15 + Float(k % 2) * 0.08, 0, 0.55 + Float(k / 2) * 0.1]
            camel.orientation = simd_quatf(angle: Float(k) * 0.9, axis: [0, 1, 0])
            field.addChild(camel)
        }
        // The white horse, Dhul-Janah, standing riderless by the tents.
        if let horse = library.instance("horse-white", fit: 0.085, along: .length) {
            horse.position = [-0.55, 0, 0.45]
            horse.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
            field.addChild(horse)
            register(horse, animation: "walk", offset: 0)
            movers.append((horse, horse.position, [0.04, 0, 0], 0))
        }
        // The companions, in white and green, in a line before the camp.
        let companions = UIColor(red: 0.82, green: 0.95, blue: 0.82, alpha: 1)
        for k in 0..<18 {
            guard let man = library.instance("warrior-hooded", fit: 0.06) else { continue }
            SceneModels.tint(man, companions)
            man.position = [-0.42 + Float(k % 2) * 0.04, 0, -0.15 + Float(k) * 0.04]
            man.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0]) // Facing the army (+x).
            field.addChild(man)
            register(man, animation: k % 3 == 0 ? "sword_slash" : "idle_sword", offset: k * 2)
        }
        banner(at: [-0.5, 0, 0.2], colour: UIColor(red: 0.2, green: 0.55, blue: 0.3, alpha: 1), in: field)

        // The Umayyad army: blocks of infantry in an arc across the field, cavalry on the wings.
        let army = UIColor(red: 1.0, green: 0.55, blue: 0.5, alpha: 1)
        let blocks: [SIMD3<Float>] = [[0.25, 0, -0.35], [0.35, 0, 0.05], [0.3, 0, 0.45], [0.75, 0, -0.2], [0.8, 0, 0.3]]
        for (b, centre) in blocks.enumerated() {
            for row in 0..<3 {
                for column in 0..<4 {
                    guard let soldier = library.instance("warrior-hooded", fit: 0.06) else { continue }
                    SceneModels.tint(soldier, army)
                    soldier.position = centre + [Float(row) * 0.05, 0, (Float(column) - 1.5) * 0.045]
                    soldier.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0]) // Facing the camp (-x).
                    field.addChild(soldier)
                    register(soldier, animation: row == 0 ? "sword_slash" : "idle_sword", offset: b * 5 + row * 3 + column)
                }
            }
            banner(at: centre + [0.17, 0, 0], colour: UIColor(red: 0.6, green: 0.1, blue: 0.1, alpha: 1), in: field)
        }
        for (w, wing) in ([[0.6, 0, -0.75], [0.65, 0, 0.8]] as [SIMD3<Float>]).enumerated() {
            for k in 0..<6 {
                guard let horse = library.instance("horse-brown", fit: 0.085, along: .length) else { continue }
                horse.position = wing + [Float(k % 3) * 0.1, 0, Float(k / 3) * 0.07]
                horse.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
                field.addChild(horse)
                register(horse, animation: "gallop", offset: w * 3 + k)
                movers.append((horse, horse.position, [-0.05, 0, 0], Float(w + k)))
            }
        }
        // The guard on the riverbank, between the camp and the water.
        for k in 0..<10 {
            guard let soldier = library.instance("warrior-hooded", fit: 0.06) else { continue }
            SceneModels.tint(soldier, army)
            soldier.position = [-0.6 + Float(k) * 0.09, 0, -0.78]
            soldier.orientation = simd_quatf(angle: 0, axis: [0, 1, 0]) // Facing the camp (+z).
            field.addChild(soldier)
            register(soldier, animation: "idle_sword", offset: k)
        }

        // The paintings, when bundled, standing behind the field like a museum backdrop.
        for (index, x) in [(1, Float(-0.8)), (2, Float(0.6))] {
            guard let image = Self.painting(index), let cg = image.cgImage,
                  let texture = try? TextureResource(image: cg, options: .init(semantic: .color)) else { continue }
            var material = UnlitMaterial(color: .white)
            material.color = .init(tint: .white, texture: .init(texture))
            let width: Float = 1.2
            let height = width * Float(image.size.height / max(image.size.width, 1))
            let canvas = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
            canvas.position = [x, height / 2 + 0.05, -1.3]
            let frame = ModelEntity(mesh: .generateBox(width: width + 0.05, height: height + 0.05, depth: 0.02),
                                    materials: [SimpleMaterial(color: UIColor(red: 0.35, green: 0.25, blue: 0.12, alpha: 1), roughness: 0.5, isMetallic: true)])
            frame.position = canvas.position - [0, 0, 0.012]
            field.addChild(frame)
            field.addChild(canvas)
        }

        // The narrator's spotlight: a soft gold ring on the ground.
        let ring = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: 1),
                               materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.84, blue: 0.4, alpha: 0.28))])
        ring.position = Self.steps[0].focus
        ring.scale = SIMD3(Self.steps[0].radius, 1, Self.steps[0].radius)
        field.addChild(ring)
        focusRing = ring

        let sun = DirectionalLight()
        sun.light.intensity = 2500
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 4, depthBias: 1)
        sun.look(at: .zero, from: [1.5, 3, 1], relativeTo: nil)
        field.addChild(sun)
        return field
    }

    private func banner(at position: SIMD3<Float>, colour: UIColor, in field: Entity) {
        guard let flag = SceneModels.shared.instance("flag-banner-long", fit: 0.14) else { return }
        SceneModels.tint(flag, colour)
        flag.position = position
        field.addChild(flag)
    }

    static func painting(_ index: Int) -> UIImage? {
        for ext in ["jpg", "jpeg", "png"] {
            if let url = Bundle.main.url(forResource: "karbala-painting-\(index)", withExtension: ext),
               let image = UIImage(contentsOfFile: url.path()) {
                return image
            }
        }
        return nil
    }

    // MARK: Animation

    /// Remembers an entity's frame groups once, so playing them costs nothing per frame.
    private func register(_ entity: Entity, animation: String, offset: Int) {
        var groups: [String: [Entity]] = [:]
        func walk(_ e: Entity) {
            for child in e.children {
                if let underscore = child.name.lastIndex(of: "_"), let index = Int(child.name[child.name.index(after: underscore)...]),
                   SceneModels.animationNames.contains(String(child.name[..<underscore])) {
                    let name = String(child.name[..<underscore])
                    var list = groups[name, default: []]
                    while list.count <= index { list.append(Entity()) }
                    list[index] = child
                    groups[name] = list
                    child.isEnabled = false
                } else {
                    walk(child)
                }
            }
        }
        walk(entity)
        guard !groups.isEmpty else { return }
        animated.append((groups, groups[animation] != nil ? animation : groups.keys.sorted()[0], offset, nil))
    }

    private func animate(by delta: Float) {
        clock += delta
        let frame = Int(clock * 10)
        if frame != lastFrame {
            lastFrame = frame
            for i in animated.indices {
                guard let frames = animated[i].groups[animated[i].animation], !frames.isEmpty else { continue }
                let next = frames[(frame + animated[i].offset) % frames.count]
                animated[i].shown?.isEnabled = false
                next.isEnabled = true
                animated[i].shown = next
            }
        }
        for mover in movers {
            mover.entity.position = mover.base + mover.swing * sin(clock * 0.8 + mover.phase)
        }
        for (k, stretch) in river.enumerated() {
            stretch.position.y = 0.004 + sin(clock * 1.5 + Float(k)) * 0.0015
        }
        if let focusRing {
            let pulse = 1 + sin(clock * 2.5) * 0.04
            focusRing.scale = SIMD3(step.radius * pulse, 1, step.radius * pulse)
        }
    }
}

private struct BattleSceneContainer: UIViewRepresentable {
    let model: BattleSceneModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        model.start(in: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject {
        let model: BattleSceneModel
        init(model: BattleSceneModel) { self.model = model }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            model.tapped(at: recognizer.location(in: recognizer.view))
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            model.pinched(recognizer.scale)
            recognizer.scale = 1
        }
    }
}
