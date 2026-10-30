import Foundation

/// The language the app is actually shown in: Arabic or English.
///
/// Read through the string catalog, the same way every on-screen label is, so it can never disagree
/// with the interface. (Bundle.preferredLocalizations reported "en" on Arabic phones, which showed
/// English city names and map labels in an Arabic app.)
enum AppLanguage {
    static let code: String = String(localized: "app.language-code", defaultValue: "en") == "ar" ? "ar" : "en"
}
