import SwiftUI

/// A round Liquid Glass button that floats over the map.
/// Group several of these inside one `GlassEffectContainer`.
struct GlassIconButton: View {
    let icon: DaldalIcon
    let label: LocalizedStringKey
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 20)
                .foregroundStyle(isActive ? Theme.accent : .primary)
                .frame(width: Theme.controlSize, height: Theme.controlSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A circular badge used for place categories in lists and cards.
struct CategoryBadge: View {
    let icon: DaldalIcon
    var size: CGFloat = 40

    var body: some View {
        Icon(icon, size: size * 0.5)
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.accent.opacity(0.14), in: .circle)
    }
}
