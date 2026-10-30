import RealityKit
import SwiftUI

/// Full-screen geographic AR for one heritage site. Walking only.
struct GeoARView: View {
    @Environment(LocationService.self) private var location
    @Environment(\.dismiss) private var dismiss
    @State private var model: GeoARModel
    @State private var dragStartCorrection: Double?

    init(site: HeritageSite, languageCode: String) {
        _model = State(initialValue: GeoARModel(site: site, languageCode: languageCode))
    }

    var body: some View {
        ZStack {
            ARContainer(model: model)
                .ignoresSafeArea()
                .gesture(alignGesture)

            if model.status == .placed, let bearing = model.relativeBearing, abs(bearing) > 25 {
                DirectionHint(bearing: bearing)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) { statusPanel }
        .animation(.smooth, value: model.status)
        .onChange(of: location.location, initial: true) { _, newValue in
            if let newValue { model.update(location: newValue) }
        }
        .onDisappear { model.stop() }
        .statusBarHidden()
        .accessibilityIdentifier("ar.screen")
    }

    /// Dragging sideways rotates the scene around the user to fix compass error.
    private var alignGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let start = dragStartCorrection ?? model.headingCorrection
                dragStartCorrection = start
                model.headingCorrection = start + Double(value.translation.width) * 0.08
            }
            .onEnded { _ in dragStartCorrection = nil }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.site.name(languageCode: model.languageCode))
                    .font(.headline)
                if let distance = model.distance {
                    Text(Measurement(value: distance, unit: UnitLength.meters),
                         format: .measurement(width: .abbreviated, usage: .road))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerRadius))

            Spacer()

            GlassIconButton(icon: .close, label: "Close") { dismiss() }
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    @ViewBuilder private var statusPanel: some View {
        if let message {
            HStack(spacing: Theme.Spacing.m) {
                if model.status == .waitingForLocation || model.isLoadingModel {
                    ProgressView()
                }
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.cornerRadius))
            .padding(Theme.Spacing.l)
        }
    }

    private var message: LocalizedStringKey? {
        switch model.status {
        case .unsupported: "This iPhone doesn't support AR."
        case .cameraDenied: "Allow camera access in Settings to see sites in AR."
        case .waitingForLocation: "Finding your position…"
        case .poorAccuracy(let meters): "Waiting for better GPS (now ±\(meters) m). Step into the open sky."
        case .tooFast: "AR is for walking. It pauses while you're in a vehicle."
        case .placed:
            model.isLoadingModel ? "Loading the 3D model…" : "Drag sideways to line the marker up with the site."
        }
    }
}

/// An arrow at the screen edge pointing toward an off-screen site.
struct DirectionHint: View {
    let bearing: Double

    var body: some View {
        Icon(.navigate, size: 28)
            .rotationEffect(.degrees(bearing - 45)) // The navigate glyph points to the top-right.
            .foregroundStyle(Theme.accent)
            .frame(width: 64, height: 64)
            .glassEffect(.regular, in: .circle)
            .frame(maxWidth: .infinity, alignment: bearing < 0 ? .leading : .trailing)
            .padding(.horizontal, Theme.Spacing.l)
            .environment(\.layoutDirection, .leftToRight) // Physical direction, not reading direction.
            .accessibilityLabel(bearing < 0 ? Text("Turn left to face the site") : Text("Turn right to face the site"))
    }
}

private struct ARContainer: UIViewRepresentable {
    let model: GeoARModel

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
