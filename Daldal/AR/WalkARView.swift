import RealityKit
import SwiftUI

/// Full-screen walking navigation in AR.
struct WalkARView: View {
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss
    @State private var model: WalkARModel
    @State private var dragStart: Double?

    init(destination: Place, provider: DaldalRouteProvider, voice: VoiceGuide) {
        _model = State(initialValue: WalkARModel(destination: destination, provider: provider, voice: voice))
    }

    private var phraser: ManeuverPhraser { ManeuverPhraser(languageCode: AppLanguage.code) }

    var body: some View {
        ZStack {
            WalkARContainer(model: model)
                .ignoresSafeArea()
                .gesture(
                    // Drag sideways to rotate the drawn path onto the real street (fixes compass error).
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            let start = dragStart ?? model.headingCorrection
                            dragStart = start
                            model.headingCorrection = start + Double(value.translation.width) * 0.08
                        }
                        .onEnded { _ in dragStart = nil }
                )

            if model.status == .guiding, let bearing = model.relativeBearing, abs(bearing) > 30 {
                DirectionHint(bearing: bearing)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) { banner }
        .overlay(alignment: .bottom) { footer }
        .animation(.smooth, value: model.status)
        .onChange(of: location.location, initial: true) { _, newValue in
            if let newValue { model.update(location: newValue) }
        }
        .onDisappear { model.stop() }
        .statusBarHidden()
        .accessibilityIdentifier("walk.screen")
    }

    @ViewBuilder private var banner: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            if model.status == .guiding, let maneuver = model.nextManeuver, let distance = model.distanceToManeuver {
                ManeuverIcon(maneuver: maneuver, size: 40)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Measurement(value: distance, unit: UnitLength.meters),
                         format: .measurement(width: .abbreviated, usage: .road))
                        .font(.title2.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(phraser.action(maneuver))
                        .font(.subheadline.weight(.semibold))
                }
            } else {
                Text(statusMessage)
                    .font(.subheadline.weight(.medium))
            }
            Spacer(minLength: 0)
            GlassIconButton(icon: .close, label: "Close") { dismiss() }
        }
        .padding(Theme.Spacing.l)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, Theme.Spacing.m)
    }

    @ViewBuilder private var footer: some View {
        if model.status == .guiding, let remaining = model.distanceRemaining {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.destination.name).font(.headline).lineLimit(1)
                    Text(Measurement(value: remaining, unit: UnitLength.meters),
                         format: .measurement(width: .abbreviated, usage: .road))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Drag sideways to line the arrows up with the street.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 160)
            }
            .padding(Theme.Spacing.l)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .padding(Theme.Spacing.m)
        }
    }

    private var statusMessage: LocalizedStringKey {
        switch model.status {
        case .routing: "Finding a walking route…"
        case .noRoute(let message): LocalizedStringKey(message)
        case .unsupported: "This iPhone doesn't support AR."
        case .cameraDenied: "Allow camera access in Settings to see sites in AR."
        case .waitingForGPS(let meters): "Waiting for better GPS (now ±\(meters) m). Step into the open sky."
        case .tooFast: "AR is for walking. It pauses while you're in a vehicle."
        case .arrived: "You've arrived."
        case .guiding: ""
        }
    }
}

private struct WalkARContainer: UIViewRepresentable {
    let model: WalkARModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        model.start(in: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}
