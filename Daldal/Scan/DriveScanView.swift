import ARKit
import RealityKit
import SwiftUI

/// Drive Scan: a 3D picture of the road around the car, built live from the camera.
struct DriveScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LocationService.self) private var location
    @State private var model: DriveScanModel
    @State private var mount = MountGuide()

    init(voice: VoiceGuide) {
        _model = State(initialValue: DriveScanModel(voice: voice))
    }

    var body: some View {
        ZStack {
            TimelineView(.animation) { timeline in
                RoadScene(objects: model.objects, warning: model.warning,
                          speed: max(location.location?.speed ?? 0, 0),
                          time: timeline.date.timeIntervalSinceReferenceDate)
            }
                .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            CameraPreview(model: model)
                .frame(width: 132, height: 176)
                .clipShape(.rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .padding(.top, 76)
                .padding(.trailing, Theme.Spacing.l)
        }
        .overlay(alignment: .top) {
            VStack(spacing: Theme.Spacing.s) {
                header
                // Until the phone is mounted well, show how to fix it; then step aside.
                if !mount.settled {
                    MountGuideView(guide: mount)
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.trailing, 140) // Clear of the camera preview.
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .overlay(alignment: .bottom) { footer }
        .animation(.smooth, value: model.warning)
        .animation(.smooth, value: mount.settled)
        .onAppear {
            model.start()
            mount.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            model.stop()
            mount.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .statusBarHidden()
        .accessibilityIdentifier("scan.screen")
        .preferredColorScheme(.light) // Tesla's light display
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            Icon(.scan, size: 22).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drive Scan").font(.headline)
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            GlassIconButton(icon: .close, label: "Close") { dismiss() }
        }
        .padding(Theme.Spacing.m)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, Theme.Spacing.m)
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: Theme.Spacing.s) {
            if model.warning {
                Text("Watch out: car close ahead")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.m)
                    .glassEffect(.regular.tint(.red.opacity(0.7)), in: .capsule)
                    .transition(.scale.combined(with: .opacity))
            }
            if let lead {
                HStack(spacing: Theme.Spacing.l) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Car ahead").font(.caption).foregroundStyle(.secondary)
                        Text(Measurement(value: lead.distance, unit: UnitLength.meters),
                             format: .measurement(width: .abbreviated, usage: .road))
                            .font(.title2.weight(.bold).monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    if let light = nearestLight {
                        Circle()
                            .fill(light == .red ? Color.red : light == .yellow ? Color.yellow : Color.green)
                            .frame(width: 26, height: 26)
                            .accessibilityLabel(light == .red ? Text("Red light") : light == .yellow ? Text("Yellow light") : Text("Green light"))
                    }
                    Spacer()
                }
                .padding(Theme.Spacing.l)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }
            Text("Mount your phone facing the road. Keep your eyes on the road; Daldal will speak if a car gets close.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.m)
    }

    private var statusLine: LocalizedStringKey {
        switch model.status {
        case .starting: "Starting the camera…"
        case .unsupported: "This iPhone doesn't support AR."
        case .cameraDenied: "Allow camera access in Settings to see sites in AR."
        case .modelMissing: "The detection model couldn't be loaded."
        case .running:
            model.hasLiDAR ? "Seeing \(model.objects.count) objects · LiDAR depth up close" : "Seeing \(model.objects.count) objects"
        }
    }

    /// The nearest vehicle roughly in our lane.
    private var lead: ScannedObject? {
        model.objects
            .filter { [.car, .truck, .bus, .motorbike].contains($0.kind) && abs($0.lateral) < 1.8 }
            .min { $0.distance < $1.distance }
    }

    private var nearestLight: ScannedObject.Light? {
        model.objects.filter { $0.kind == .trafficLight && $0.light != nil }.min { $0.distance < $1.distance }?.light
    }
}

// MARK: 3D road

/// The road around the car, drawn the way Tesla's driving display does it: a calm light-grey world, soft grey
/// lane lines, our car glossy black from behind, everyone else as smooth light-grey shapes and white figures.
/// Everything is built from simple shapes in code, so it appears instantly and uses little memory.
/// Reused by the full-screen Drive Scan and by Drive Mode's split view.
struct RoadScene: View {
    let objects: [ScannedObject]
    let warning: Bool
    /// Metres per second; the lane markings stream past at this speed.
    var speed: Double = 0
    /// The next turn, drawn as an arrow on the road once it's within reach.
    var turn: Maneuver? = nil
    var turnDistance: Double? = nil
    /// Animation clock (seconds); drives the moving road.
    var time: TimeInterval = 0

    /// Detected objects are drawn this much further ahead than measured, so they never crowd our car's nose.
    static let clearance: Float = 2.5

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            let world = Entity()
            world.name = "world"
            world.addChild(Road.make())

            let ego = Vehicles.car(paint: Vehicles.egoPaint, lit: true)
            ego.position = [0, 0, 2.3] // Nose at z = 0, where the phone (windscreen) is.
            world.addChild(ego)

            // Soft, even light from above, like an overcast sky, with gentle shadows under the cars.
            let key = DirectionalLight()
            key.light.intensity = 3200
            key.shadow = DirectionalLightComponent.Shadow(maximumDistance: 60, depthBias: 2)
            key.look(at: [0, 0, -12], from: [3, 20, 4], relativeTo: nil)
            world.addChild(key)
            let fill = DirectionalLight()
            fill.light.intensity = 1400
            fill.look(at: .zero, from: [-4, 8, 14], relativeTo: nil)
            world.addChild(fill)

            // Low behind our car, looking down the road.
            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 52
            camera.look(at: [0, 0, -20], from: [0, 5.2, 11.5], relativeTo: nil)
            world.addChild(camera)
            content.add(world)
        } update: { content in
            guard let world = content.entities.first(where: { $0.name == "world" }) else { return }
            Road.move(world, travelled: Float(time * speed))
            Road.showTurn(world, turn: turn, distance: turnDistance)
            let live = Set(objects.map { "object-\($0.id)" })
            for child in world.children where child.name.hasPrefix("object-") && !live.contains(child.name) {
                child.removeFromParent()
            }
            for object in objects {
                let name = "object-\(object.id)"
                let target = SIMD3<Float>(Float(object.lateral), 0, -Float(object.distance) - Self.clearance)
                if let entity = world.children.first(where: { $0.name == name }) {
                    // Glide towards each new measurement: detections are noisy from frame to frame.
                    entity.position += (target - entity.position) * 0.2
                } else {
                    let made = ObjectModels.make(object.kind)
                    made.name = name
                    made.position = target
                    world.addChild(made)
                }
                guard let entity = world.children.first(where: { $0.name == name }) else { continue }
                ObjectModels.style(entity, for: object, danger: warning && abs(object.lateral) < 1.6)
            }
        }
        .background(
            // The horizon fades into a pale sky, as on Tesla's screen.
            LinearGradient(colors: [Color(white: 0.97), Color(white: 0.9), Color(white: 0.86)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

/// A light-grey ground with soft grey lane lines; three 3.5 m lanes.
private enum Road {
    static let ground = UIColor(white: 0.88, alpha: 1)

    static func make() -> Entity {
        let road = Entity()
        // Unlit so the ground is one even tone that melts into the sky at the horizon.
        let surface = ModelEntity(mesh: .generatePlane(width: 160, depth: 220), materials: [UnlitMaterial(color: ground)])
        surface.position = [0, 0, -80]
        road.addChild(surface)

        let edge = UnlitMaterial(color: UIColor(white: 0.66, alpha: 1))
        for x: Float in [-5.25, 5.25] {
            let line = ModelEntity(mesh: .generateBox(width: 0.12, height: 0.004, depth: 120), materials: [edge])
            line.position = [x, 0.005, -50]
            road.addChild(line)
        }
        let dash = UnlitMaterial(color: UIColor(white: 0.72, alpha: 1))
        for x: Float in [-1.75, 1.75] {
            for k in 0..<dashCount {
                let piece = ModelEntity(mesh: .generateBox(width: 0.1, height: 0.004, depth: 3), materials: [dash])
                piece.name = "dash-\(k)"
                piece.position = [x, 0.005, 6 - Float(k) * dashSpacing]
                road.addChild(piece)
            }
        }

        // The next turn: a blue arrow painted on the road, pointing along -z.
        let glow = UnlitMaterial(color: UIColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 0.85))
        let arrow = Entity()
        arrow.name = "turn-arrow"
        let shaft = ModelEntity(mesh: .generateBox(width: 0.7, height: 0.01, depth: 4.5, cornerRadius: 0.2), materials: [glow])
        shaft.position = [0, 0.012, 0]
        arrow.addChild(shaft)
        for side: Float in [-1, 1] {
            let wing = ModelEntity(mesh: .generateBox(width: 0.7, height: 0.01, depth: 2.6, cornerRadius: 0.2), materials: [glow])
            wing.position = [side * 0.75, 0.012, -2.2]
            wing.orientation = simd_quatf(angle: side * -0.8, axis: [0, 1, 0])
            arrow.addChild(wing)
        }
        arrow.isEnabled = false
        road.addChild(arrow)
        road.name = "road"
        return road
    }

    static let dashCount = 12
    static let dashSpacing: Float = 9

    /// Streams the lane dashes towards the camera as the car moves.
    static func move(_ world: Entity, travelled: Float) {
        guard let road = world.findEntity(named: "road") else { return }
        let offset = travelled.truncatingRemainder(dividingBy: dashSpacing)
        for child in road.children where child.name.hasPrefix("dash-") {
            guard let k = Int(child.name.dropFirst(5)) else { continue }
            child.position.z = 6 - Float(k) * dashSpacing + offset
        }
    }

    /// Shows the next turn on the road surface when it's within 120 m, pointing the way to go.
    static func showTurn(_ world: Entity, turn: Maneuver?, distance: Double?) {
        guard let arrow = world.findEntity(named: "turn-arrow") else { return }
        guard let turn, let distance, distance < 120 else {
            arrow.isEnabled = false
            return
        }
        let yaw: Float = switch turn.direction {
        case .left, .sharpLeft: .pi / 2
        case .slightLeft: .pi / 4
        case .right, .sharpRight: -.pi / 2
        case .slightRight: -.pi / 4
        case .uTurn: .pi
        default: 0
        }
        arrow.isEnabled = true
        arrow.position = [0, 0, -Float(max(distance, 8))]
        arrow.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
    }
}

/// Smooth, rounded vehicle shapes: a low body, a glass cabin set back, dark wheels. No logos, no colours.
private enum Vehicles {
    static var egoPaint: PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(white: 0.08, alpha: 1))
        m.roughness = 0.18
        m.metallic = 0.4
        m.clearcoat = .init(floatLiteral: 1)
        m.clearcoatRoughness = .init(floatLiteral: 0.03)
        return m
    }

    static var otherPaint: PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(white: 0.80, alpha: 1))
        m.roughness = 0.42
        m.metallic = 0.0
        m.clearcoat = .init(floatLiteral: 0.6)
        m.clearcoatRoughness = .init(floatLiteral: 0.2)
        return m
    }

    static func car(paint: PhysicallyBasedMaterial, lit: Bool, length: Float = 4.6, width: Float = 1.9, height: Float = 1.45) -> Entity {
        let car = Entity()
        // Lower body, generously rounded, and a slightly narrower shoulder line on top of it.
        let body = ModelEntity(mesh: .generateBox(width: width, height: height * 0.42, depth: length, cornerRadius: 0.34),
                               materials: [paint])
        body.position.y = height * 0.33
        car.addChild(body)
        let shoulder = ModelEntity(mesh: .generateBox(width: width * 0.94, height: height * 0.14, depth: length * 0.9, cornerRadius: 0.12),
                                   materials: [paint])
        shoulder.position.y = height * 0.56
        car.addChild(shoulder)

        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: UIColor(white: lit ? 0.04 : 0.55, alpha: 1))
        glass.roughness = 0.08
        glass.metallic = 0.2
        let cabin = ModelEntity(mesh: .generateBox(width: width * 0.82, height: height * 0.36, depth: length * 0.48, cornerRadius: 0.32),
                                materials: [glass])
        cabin.position = [0, height * 0.78, length * 0.04]
        car.addChild(cabin)

        var rubber = PhysicallyBasedMaterial()
        rubber.baseColor = .init(tint: UIColor(white: lit ? 0.05 : 0.45, alpha: 1))
        rubber.roughness = 0.9
        for (x, z) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] as [(Float, Float)] {
            let wheel = ModelEntity(mesh: .generateCylinder(height: 0.22, radius: 0.33), materials: [rubber])
            wheel.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            wheel.position = [x * (width / 2 - 0.1), 0.33, z * length * 0.32]
            car.addChild(wheel)
        }

        if lit {
            // Our car, seen from behind: a thin red light bar across the tail.
            let bar = ModelEntity(mesh: .generateBox(width: width * 0.86, height: 0.05, depth: 0.03, cornerRadius: 0.02),
                                  materials: [UnlitMaterial(color: UIColor(red: 0.95, green: 0.12, blue: 0.14, alpha: 1))])
            bar.position = [0, height * 0.5, length / 2 + 0.005]
            car.addChild(bar)
        }
        car.components.set(GroundingShadowComponent(castsShadow: true))
        for child in car.children { child.components.set(GroundingShadowComponent(castsShadow: true)) }
        return car
    }

    /// A white figure, like Tesla's pedestrians: rounded body, head, legs; no faces or clothes.
    static func person() -> Entity {
        var white = PhysicallyBasedMaterial()
        white.baseColor = .init(tint: UIColor(white: 0.97, alpha: 1))
        white.roughness = 0.5
        let person = Entity()
        let torso = ModelEntity(mesh: .generateBox(width: 0.44, height: 0.66, depth: 0.26, cornerRadius: 0.13), materials: [white])
        torso.position.y = 1.2
        person.addChild(torso)
        let head = ModelEntity(mesh: .generateSphere(radius: 0.13), materials: [white])
        head.position.y = 1.67
        person.addChild(head)
        for side: Float in [-1, 1] {
            let leg = ModelEntity(mesh: .generateBox(width: 0.16, height: 0.86, depth: 0.17, cornerRadius: 0.07), materials: [white])
            leg.position = [side * 0.11, 0.44, 0]
            person.addChild(leg)
            let arm = ModelEntity(mesh: .generateBox(width: 0.1, height: 0.6, depth: 0.11, cornerRadius: 0.05), materials: [white])
            arm.position = [side * 0.28, 1.18, 0]
            arm.orientation = simd_quatf(angle: side * 0.1, axis: [0, 0, 1])
            person.addChild(arm)
        }
        person.components.set(GroundingShadowComponent(castsShadow: true))
        return person
    }
}

/// Shapes for each kind of road user, all in the same calm grey and white.
private enum ObjectModels {
    static func make(_ kind: ScannedObject.Kind) -> Entity {
        let root = Entity()
        let grey = Vehicles.otherPaint
        switch kind {
        case .car:
            root.addChild(Vehicles.car(paint: grey, lit: false))
        case .truck:
            root.addChild(Vehicles.car(paint: grey, lit: false, length: 8, width: 2.5, height: 3.2))
        case .bus:
            root.addChild(Vehicles.car(paint: grey, lit: false, length: 11, width: 2.55, height: 3.2))
        case .train:
            root.addChild(Vehicles.car(paint: grey, lit: false, length: 20, width: 3, height: 3.8))
        case .motorbike, .bicycle:
            let frame = ModelEntity(mesh: .generateBox(width: 0.35, height: 0.85, depth: 1.9, cornerRadius: 0.17), materials: [grey])
            frame.position.y = 0.5
            root.addChild(frame)
            let rider = Vehicles.person()
            rider.scale = SIMD3(repeating: 0.85)
            rider.position = [0, 0.35, 0.1]
            root.addChild(rider)
        case .person, .animal:
            root.addChild(Vehicles.person())
        case .trafficLight:
            let pole = ModelEntity(mesh: .generateCylinder(height: 4.6, radius: 0.07), materials: [grey])
            pole.position.y = 2.3
            root.addChild(pole)
            let housing = ModelEntity(mesh: .generateBox(width: 0.42, height: 1.2, depth: 0.32, cornerRadius: 0.08),
                                      materials: [SimpleMaterial(color: UIColor(white: 0.3, alpha: 1), isMetallic: false)])
            housing.position.y = 5.0
            root.addChild(housing)
            for (index, name) in ["lamp-red", "lamp-yellow", "lamp-green"].enumerated() {
                let lamp = ModelEntity(mesh: .generateSphere(radius: 0.13), materials: [UnlitMaterial(color: UIColor(white: 0.5, alpha: 1))])
                lamp.name = name
                lamp.position = [0, 5.37 - Float(index) * 0.37, 0.17]
                root.addChild(lamp)
            }
        case .stopSign:
            let pole = ModelEntity(mesh: .generateCylinder(height: 2.2, radius: 0.05), materials: [grey])
            pole.position.y = 1.1
            root.addChild(pole)
            let sign = ModelEntity(mesh: .generateBox(width: 0.75, height: 0.75, depth: 0.04, cornerRadius: 0.22),
                                   materials: [UnlitMaterial(color: UIColor(red: 0.85, green: 0.1, blue: 0.12, alpha: 1))])
            sign.position.y = 2.45
            root.addChild(sign)
        }
        // A soft red pool under anything that triggers the collision warning.
        let ring = ModelEntity(mesh: .generateBox(width: 2.6, height: 0.01, depth: 5.4, cornerRadius: 1.2),
                               materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.35))])
        ring.name = "danger"
        ring.position.y = 0.012
        ring.isEnabled = false
        root.addChild(ring)
        return root
    }

    static func style(_ entity: Entity, for object: ScannedObject, danger: Bool) {
        entity.findEntity(named: "danger")?.isEnabled = danger && [.car, .truck, .bus, .motorbike].contains(object.kind)
        guard object.kind == .trafficLight else { return }
        let lit: String? = switch object.light {
        case .red: "lamp-red"
        case .yellow: "lamp-yellow"
        case .green: "lamp-green"
        case nil: nil
        }
        let colors: [String: UIColor] = ["lamp-red": .systemRed, "lamp-yellow": .systemYellow, "lamp-green": .systemGreen]
        for name in colors.keys {
            let on = name == lit
            (entity.findEntity(named: name) as? ModelEntity)?.model?.materials =
                [UnlitMaterial(color: on ? colors[name]! : UIColor(white: 0.5, alpha: 1))]
        }
    }
}

// MARK: Camera preview

/// The live camera, small, with what the model found outlined on it.
private struct CameraPreview: View {
    let model: DriveScanModel

    var body: some View {
        ARCameraFeed(session: model.session)
            .overlay {
                GeometryReader { geometry in
                    ForEach(model.objects) { object in
                        let r = object.box
                        Rectangle()
                            .strokeBorder(object.kind == .person ? Color.orange : Theme.accent, lineWidth: 1.5)
                            .frame(width: r.width * geometry.size.width, height: r.height * geometry.size.height)
                            .position(x: r.midX * geometry.size.width, y: r.midY * geometry.size.height)
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

private struct ARCameraFeed: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        view.renderOptions.formUnion([.disableMotionBlur, .disableDepthOfField, .disablePersonOcclusion])
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
