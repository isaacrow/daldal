import CoreLocation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Share -> Daldal" from any app: reads the location in what was shared (a Google Maps, Waze or Apple Maps link,
/// coordinates, or a message containing one), shows it, and opens Daldal there with directions one tap away.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.onOpen = { [weak self] url in self?.openDaldal(url) }
        model.onCancel = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.read(extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }

    /// Opens Daldal at the place. Extensions can't open apps directly, so the request goes up the responder chain
    /// to the application; the link is also copied, so Daldal offers it on its own if that's ever refused.
    private func openDaldal(_ url: URL) {
        if let found = model.found {
            UIPasteboard.general.url = LocationLink.shareURL(for: found.coordinate)
        }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                break
            }
            responder = current.next
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@Observable
final class ShareModel {
    enum State { case reading, found, notFound }

    private(set) var state: State = .reading
    private(set) var found: LocationLink.Found?
    var onOpen: (URL) -> Void = { _ in }
    var onCancel: () -> Void = {}

    /// Collects every link and piece of text shared, then looks for a location in them (following short links).
    func read(_ items: [NSExtensionItem]) async {
        var texts: [String] = []
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty { texts.append(text) }
            for provider in item.attachments ?? [] {
                if let text = await Self.text(from: provider) { texts.append(text) }
            }
        }
        for text in texts {
            if let location = await LocationLink.resolve(text) {
                found = location
                state = .found
                return
            }
        }
        state = .notFound
    }

    /// A shared link or text, read off the main thread where item providers deliver.
    nonisolated private static func text(from provider: NSItemProvider) async -> String? {
        if provider.canLoadObject(ofClass: URL.self) {
            return await withCheckedContinuation { done in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url?.absoluteString) }
            }
        }
        if provider.canLoadObject(ofClass: String.self) {
            return await withCheckedContinuation { done in
                _ = provider.loadObject(ofClass: String.self) { text, _ in done.resume(returning: text) }
            }
        }
        return nil
    }

    var daldalURL: URL? {
        guard let found else { return nil }
        var components = URLComponents()
        components.scheme = "daldal"
        components.host = "place"
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.6f", found.coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.6f", found.coordinate.longitude)),
        ] + (found.name.map { [URLQueryItem(name: "name", value: $0)] } ?? [])
        return components.url
    }
}

struct ShareView: View {
    let model: ShareModel

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(.secondary.opacity(0.4)).frame(width: 40, height: 5)
            Text("Daldal").font(.headline)
            switch model.state {
            case .reading:
                ProgressView()
                Text("Finding the location…").foregroundStyle(.secondary)
            case .found:
                if let found = model.found {
                    VStack(spacing: 6) {
                        Text(found.name ?? String(localized: "Shared location"))
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text(String(format: "%.5f, %.5f", found.coordinate.latitude, found.coordinate.longitude))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    if let url = model.daldalURL { model.onOpen(url) }
                } label: {
                    Text("Open in Daldal").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.05, green: 0.6, blue: 0.55))
            case .notFound:
                Text("No location in what was shared. Share a map link or coordinates.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") { model.onCancel() }
                .padding(.bottom, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}
