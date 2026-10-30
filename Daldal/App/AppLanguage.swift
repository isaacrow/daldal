import Foundation

/// The language the app is actually shown in: Arabic or English.
///
/// Read from the bundle, not the phone's locale. A phone set to French or Kurdish shows Daldal in
/// Arabic (the development region), and map labels, search and voice must follow the UI, not the phone.
enum AppLanguage {
    static let code: String = Bundle.main.preferredLocalizations.first == "en" ? "en" : "ar"
}
