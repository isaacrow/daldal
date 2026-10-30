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

/// RealityKit scene with a virtual camera: our car, the road and lanes, and everything detected around us.
private struct RoadScene: View {
    let objects: [ScannedObject]
    let warning: Bool

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            let world = Entity()
            world.name = "world"

            let asphalt = SimpleMaterial(color: UIColor(white: 0.16, alpha: 1), roughness: 0.9, isMetallic: false)
            let road = ModelEntity(mesh: .generatePlane(width: 12, depth: 90), materials: [asphalt])
            road.position = [0, 0, -38]
            world.addChild(road)

            // Dashed lane lines, 3.5 m lanes like Iraqi highways.
            let paint = UnlitMaterial(color: UIColor(white: 0.85, alpha: 0.8))
            for x: Float in [-5.25, -1.75, 1.75, 5.25] {
                for z in stride(from: Float(4), to: -80, by: -6) {
                    let dash = ModelEntity(mesh: .generateBox(width: 0.12, height: 0.01, depth: 2.4), materials: [paint])
                    dash.position = [x, 0.01, z]
                    world.addChild(dash)
                }
            }

            let ego = ModelEntity(mesh: .generateBox(width: 1.85, height: 1.35, depth: 4.5, cornerRadius: 0.35),
                                  materials: [SimpleMaterial(color: UIColor(named: "AccentColor") ?? .systemTeal,
                                                             roughness: 0.3, isMetallic: true)])
            ego.position = [0, 0.68, 2.25]
            world.addChild(ego)

            let light = DirectionalLight()
            light.light.intensity = 3000
            light.look(at: .zero, from: [4, 10, 6], relativeTo: nil)
            world.addChild(light)

            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 55
            camera.look(at: [0, 0, -14], from: [0, 7.5, 10.5], relativeTo: nil)
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
                // The ego car's nose is at z = 0; detections are measured from the phone (windscreen).
                entity.position = [Float(object.lateral), 0, -Float(object.distance)]
                ObjectModels.style(entity, for: object, danger: warning && abs(object.lateral) < 1.6)
            }
        }
    }
}

/// Simple, readable shapes for each kind of road user.
private enum ObjectModels {
    static func make(_ kind: ScannedObject.Kind) -> Entity {
        let root = Entity()
        let body: ModelEntity
        switch kind {
        case .car:
            body = ModelEntity(mesh: .generateBox(width: 1.8, height: 1.4, depth: 4.4, cornerRadius: 0.3), materials: [grey])
            body.position.y = 0.7
        case .truck, .bus:
            body = ModelEntity(mesh: .generateBox(width: 2.5, height: 3.1, depth: kind == .bus ? 11 : 8, cornerRadius: 0.25),
                               materials: [grey])
            body.position.y = 1.55
        case .motorbike, .bicycle:
            body = ModelEntity(mesh: .generateBox(width: 0.6, height: 1.2, depth: 1.9, cornerRadius: 0.2), materials: [grey])
            body.position.y = 0.6
        case .person:
            body = ModelEntity(mesh: .generateCylinder(height: 1.7, radius: 0.28), materials: [UnlitMaterial(color: .systemOrange)])
            body.position.y = 0.85
        case .trafficLight:
            let pole = ModelEntity(mesh: .generateCylinder(height: 4.5, radius: 0.08), materials: [grey])
            pole.position.y = 2.25
            root.addChild(pole)
            body = ModelEntity(mesh: .generateSphere(radius: 0.4), materials: [UnlitMaterial(color: .gray)])
            body.position.y = 4.7
        case .stopSign:
            let pole = ModelEntity(mesh: .generateCylinder(height: 2.2, radius: 0.05), materials: [grey])
            pole.position.y = 1.1
            root.addChild(pole)
            body = ModelEntity(mesh: .generateBox(width: 0.75, height: 0.75, depth: 0.05, cornerRadius: 0.2),
                               materials: [UnlitMaterial(color: .systemRed)])
            body.position.y = 2.4
        }
        body.name = "body"
        root.addChild(body)
        return root
    }

    static func style(_ entity: Entity, for object: ScannedObject, danger: Bool) {
        guard let body = entity.children.first(where: { $0.name == "body" }) as? ModelEntity else { return }
        switch object.kind {
        case .trafficLight:
            let color: UIColor = switch object.light {
            case .red: .systemRed
            case .yellow: .systemYellow
            case .green: .systemGreen
            case nil: .gray
            }
            body.model?.materials = [UnlitMaterial(color: color)]
        case .car, .truck, .bus, .motorbike, .bicycle:
            body.model?.materials = [danger ? UnlitMaterial(color: .systemRed) : grey]
        default:
            break
        }
    }

    static var grey: SimpleMaterial { SimpleMaterial(color: UIColor(white: 0.78, alpha: 1), roughness: 0.5, isMetallic: false) }
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
