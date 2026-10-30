import SwiftUI

enum Theme {
    /// Brand teal. Lives in the asset catalog so it adapts to dark mode.
    static let accent = Color.accentColor

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Minimum hit target for anything a driver may touch.
    static let controlSize: CGFloat = 48
    static let cornerRadius: CGFloat = 22
}

extension Font {
    static let placeTitle = Font.title2.weight(.semibold)
    static let rowTitle = Font.body.weight(.medium)
}
