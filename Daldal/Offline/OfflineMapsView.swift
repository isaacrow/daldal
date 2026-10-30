import SwiftUI

/// Download, update or remove the offline Iraq map, and check the voice.
struct OfflineMapsView: View {
    @Environment(OfflinePackManager.self) private var packs
    @Environment(NavigationModel.self) private var nav
    @Environment(LiveStore.self) private var live
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @AppStorage("traffic.share") private var shareTraffic = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    packRow
                } footer: {
                    Text("With the Iraq map on your phone, the map, search and directions all work without internet. Live traffic still needs a connection.")
                }

                if live.isAvailable {
                    Section {
                        Toggle(isOn: $shareTraffic) {
                            HStack(spacing: Theme.Spacing.m) {
                                CategoryBadge(icon: .traffic, size: 36)
                                Text("Help with live traffic").font(.rowTitle)
                            }
                        }
                    } footer: {
                        Text("While you navigate, your speed is shared anonymously: a new random code each trip, never the first or last 300 m, and only averages from several drivers are kept.")
                    }
                }

                Section {
                    HStack(spacing: Theme.Spacing.m) {
                        CategoryBadge(icon: .volume, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice guidance").font(.rowTitle)
                            Text(nav.voice.hasHighQualityVoice ? "Using a high-quality voice" : "Using the basic voice")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if !nav.voice.hasHighQualityVoice {
                        Text("For clearer directions, download an Enhanced Arabic voice in Settings › Accessibility › Spoken Content › Voices › Arabic.")
                    }
                }
            }
            .navigationTitle("Offline maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Icon(.close, size: 16) }
                        .accessibilityLabel("Close")
                }
            }
            .task { await packs.checkForUpdate() }
            .confirmationDialog("Remove the Iraq map from this iPhone?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { packs.delete() }
            }
        }
    }

    @ViewBuilder private var packRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.m) {
                CategoryBadge(icon: .download, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Iraq").font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            switch packs.state {
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                Text("\(received.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .verifying:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .checking:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .failed(let message):
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                actionButton("Retry", icon: .download) { Task { await packs.download() } }
            case .notInstalled:
                actionButton("Download", icon: .download) { Task { await packs.download() } }
            case .installed:
                HStack {
                    if packs.updateAvailable {
                        actionButton("Update", icon: .download) { Task { await packs.download() } }
                    }
                    Spacer()
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label { Text("Remove") } icon: { Icon(.trash, size: 16) }
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var subtitle: String {
        switch packs.state {
        case .installed:
            if let version = packs.installed?.version { return String(localized: "Downloaded · version \(version)") }
            return String(localized: "Downloaded")
        case .downloading: return String(localized: "Downloading… you can leave the app.")
        case .verifying: return String(localized: "Checking files…")
        default:
            if let bytes = packs.publishedBytes { return bytes.formatted(.byteCount(style: .file)) }
            return String(localized: "Map, search and directions")
        }
    }

    private func actionButton(_ title: LocalizedStringKey, icon: DaldalIcon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { Icon(icon, size: 16) }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
    }
}
