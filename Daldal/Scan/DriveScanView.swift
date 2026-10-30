import ARKit
import RealityKit
import SwiftUI

/// Drive Scan: a 3D picture of the road around the car, built live from the camera.
struct DriveScanView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: DriveScanModel

    init(voice: VoiceGuide) {
        _model = State(initialValue: DriveScanModel(voice: voice))
    }

    var body: some View {
        ZStack {
            RoadScene(objects: model.objects, warning: model.warning)
                .ignoresSafeArea()
                .background(Color.black)
        }
        .overlay(alignment: .topTrailing) {
            CameraPreview(model: model)
                .frame(width: 132, height: 176)
                .clipShape(.rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .padding(.top, 76)
                .padding(.trailing, Theme.Spacing.l)
        }
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) { footer }
        .animation(.smooth, value: model.warning)
        .onAppear {
            model.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            model.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .statusBarHidden()
        .accessibilityIdentifier("scan.screen")
        .preferredColorScheme(.dark)
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

/// RealityKit scene with a virtual camera: our car, the road, and everything detected around us,
/// rendered with physically based materials and shadowed lighting.
private struct RoadScene: View {
    let objects: [ScannedObject]
    let warning: Bool

    var body: some View {
        RealityView { content in
            content.camera = .virtual

            let world = Entity()
            world.name = "world"
            world.addChild(Road.make())

            let ego = CarModel.make(paint: CarModel.pearl, lit: true)
            ego.position = [0, 0, 2.3] // Nose at z = 0, where the phone (windscreen) is.
            world.addChild(ego)

            // Key light with shadows, from ahead-right like a late-afternoon sun, plus a soft fill.
            let sun = DirectionalLight()
            sun.light.intensity = 4200
            sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 45, depthBias: 3)
            sun.look(at: [0, 0, -10], from: [8, 14, -2], relativeTo: nil)
            world.addChild(sun)
            let fill = DirectionalLight()
            fill.light.intensity = 900
            fill.look(at: .zero, from: [-6, 6, 12], relativeTo: nil)
            world.addChild(fill)

            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 48
            camera.look(at: [0, 0.4, -16], from: [0, 5.2, 9.5], relativeTo: nil)
            world.addChild(camera)
            content.add(world)
        } update: { content in
            guard let world = content.entities.first(where: { $0.name == "world" }) else { return }
            let live = Set(objects.map { "object-\($0.id)" })
            for child in world.children where child.name.hasPrefix("object-") && !live.contains(child.name) {
                child.removeFromParent()
            }
            for object in objects {
                let name = "object-\(object.id)"
                let entity = world.children.first { $0.name == name } ?? {
                    let made = ObjectModels.make(object.kind)
                    made.name = name
                    world.addChild(made)
                    return made
                }()
                entity.position = [Float(object.lateral), 0, -Float(object.distance)]
                ObjectModels.style(entity, for: object, danger: warning && abs(object.lateral) < 1.6)
            }
        }
    }
}

/// Dark asphalt with solid edge lines and soft lane dashes; three 3.5 m lanes.
private enum Road {
    static func make() -> Entity {
        let road = Entity()
        var asphalt = PhysicallyBasedMaterial()
        asphalt.baseColor = .init(tint: UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1))
        asphalt.roughness = 0.95
        let surface = ModelEntity(mesh: .generatePlane(width: 11.5, depth: 75), materials: [asphalt])
        surface.position = [0, 0, -30]
        road.addChild(surface)

        let edge = UnlitMaterial(color: UIColor(white: 0.92, alpha: 0.9))
        for x: Float in [-5.25, 5.25] {
            let line = ModelEntity(mesh: .generateBox(width: 0.14, height: 0.005, depth: 75), materials: [edge])
            line.position = [x, 0.006, -30]
            road.addChild(line)
        }
        let dash = UnlitMaterial(color: UIColor(white: 0.85, alpha: 0.45))
        for x: Float in [-1.75, 1.75] {
            for z in stride(from: Float(6), to: -66, by: -9) {
                let piece = ModelEntity(mesh: .generateBox(width: 0.1, height: 0.005, depth: 3), materials: [dash])
                piece.position = [x, 0.006, z]
                road.addChild(piece)
            }
        }
        return road
    }
}

/// A car built from parts (body, cabin glass, wheels, lights), so it reads as a car at a glance.
private enum CarModel {
    static var pearl: PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(white: 0.96, alpha: 1))
        m.roughness = 0.22
        m.metallic = 0.35
        m.clearcoat = .init(floatLiteral: 1)
        m.clearcoatRoughness = .init(floatLiteral: 0.04)
        return m
    }

    static var graphite: PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(white: 0.62, alpha: 1))
        m.roughness = 0.45
        m.metallic = 0.2
        return m
    }

    static func make(paint: PhysicallyBasedMaterial, lit: Bool, length: Float = 4.5, width: Float = 1.85, height: Float = 1.45) -> Entity {
        let car = Entity()
        let body = ModelEntity(mesh: .generateBox(width: width, height: height * 0.45, depth: length, cornerRadius: 0.28),
                               materials: [paint])
        body.name = "body"
        body.position.y = height * 0.38
        car.addChild(body)

        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: UIColor(red: 0.05, green: 0.08, blue: 0.12, alpha: 1))
        glass.roughness = 0.05
        glass.metallic = 0.6
        glass.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        let cabin = ModelEntity(mesh: .generateBox(width: width * 0.86, height: height * 0.4, depth: length * 0.5, cornerRadius: 0.3),
                                materials: [glass])
        cabin.position = [0, height * 0.78, length * 0.06]
        car.addChild(cabin)

        var rubber = PhysicallyBasedMaterial()
        rubber.baseColor = .init(tint: UIColor(white: 0.06, alpha: 1))
        rubber.roughness = 0.9
        for (x, z) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] as [(Float, Float)] {
            let wheel = ModelEntity(mesh: .generateCylinder(height: 0.24, radius: 0.34), materials: [rubber])
            wheel.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            wheel.position = [x * (width / 2 - 0.08), 0.34, z * length * 0.32]
            car.addChild(wheel)
        }

        if lit {
            for x: Float in [-0.6, 0.6] {
                let head = ModelEntity(mesh: .generateBox(width: 0.38, height: 0.08, depth: 0.04, cornerRadius: 0.03),
                                       materials: [UnlitMaterial(color: UIColor(white: 1, alpha: 1))])
                head.position = [x, height * 0.45, -length / 2]
                car.addChild(head)
                let tail = ModelEntity(mesh: .generateBox(width: 0.42, height: 0.07, depth: 0.04, cornerRadius: 0.03),
                                       materials: [UnlitMaterial(color: UIColor(red: 0.95, green: 0.1, blue: 0.12, alpha: 1))])
                tail.position = [x, height * 0.5, length / 2]
                car.addChild(tail)
            }
        }
        car.components.set(GroundingShadowComponent(castsShadow: true))
        for child in car.children { child.components.set(GroundingShadowComponent(castsShadow: true)) }
        return car
    }
}

/// Readable shapes for each kind of road user.
private enum ObjectModels {
    static func make(_ kind: ScannedObject.Kind) -> Entity {
        let root = Entity()
        switch kind {
        case .car:
            root.addChild(CarModel.make(paint: CarModel.graphite, lit: false))
        case .truck:
            root.addChild(CarModel.make(paint: CarModel.graphite, lit: false, length: 8, width: 2.5, height: 3.3))
        case .bus:
            root.addChild(CarModel.make(paint: CarModel.graphite, lit: false, length: 11, width: 2.55, height: 3.2))
        case .motorbike, .bicycle:
            let frame = ModelEntity(mesh: .generateBox(width: 0.35, height: 0.9, depth: 1.9, cornerRadius: 0.15),
                                    materials: [CarModel.graphite])
            frame.name = "body"
            frame.position.y = 0.55
            root.addChild(frame)
            let rider = ModelEntity(mesh: .generateSphere(radius: 0.18), materials: [UnlitMaterial(color: .systemOrange)])
            rider.position = [0, 1.45, 0.1]
            root.addChild(rider)
        case .person:
            let figure = UnlitMaterial(color: UIColor(red: 1, green: 0.62, blue: 0.2, alpha: 1))
            let torso = ModelEntity(mesh: .generateBox(width: 0.42, height: 1.15, depth: 0.28, cornerRadius: 0.14), materials: [figure])
            torso.position.y = 0.75
            root.addChild(torso)
            let head = ModelEntity(mesh: .generateSphere(radius: 0.15), materials: [figure])
            head.position.y = 1.55
            root.addChild(head)
        case .trafficLight:
            let pole = ModelEntity(mesh: .generateCylinder(height: 4.6, radius: 0.07), materials: [CarModel.graphite])
            pole.position.y = 2.3
            root.addChild(pole)
            let housing = ModelEntity(mesh: .generateBox(width: 0.42, height: 1.2, depth: 0.32, cornerRadius: 0.08),
                                      materials: [SimpleMaterial(color: UIColor(white: 0.08, alpha: 1), isMetallic: false)])
            housing.position.y = 5.0
            root.addChild(housing)
            for (index, name) in ["lamp-red", "lamp-yellow", "lamp-green"].enumerated() {
                let lamp = ModelEntity(mesh: .generateSphere(radius: 0.13), materials: [UnlitMaterial(color: UIColor(white: 0.18, alpha: 1))])
                lamp.name = name
                lamp.position = [0, 5.37 - Float(index) * 0.37, 0.17]
                root.addChild(lamp)
            }
        case .stopSign:
            let pole = ModelEntity(mesh: .generateCylinder(height: 2.2, radius: 0.05), materials: [CarModel.graphite])
            pole.position.y = 1.1
            root.addChild(pole)
            let sign = ModelEntity(mesh: .generateBox(width: 0.75, height: 0.75, depth: 0.04, cornerRadius: 0.22),
                                   materials: [UnlitMaterial(color: UIColor(red: 0.85, green: 0.1, blue: 0.12, alpha: 1))])
            sign.position.y = 2.45
            root.addChild(sign)
        }
        // A red glow under anything that triggers the collision warning.
        let ring = ModelEntity(mesh: .generateBox(width: 2.6, height: 0.01, depth: 5.4, cornerRadius: 1.2),
                               materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.15, blue: 0.15, alpha: 0.45))])
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
                [UnlitMaterial(color: on ? colors[name]! : UIColor(white: 0.18, alpha: 1))]
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
