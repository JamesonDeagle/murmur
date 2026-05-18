import Foundation

/// Minimal Russian/English localization layer.
///
/// Why not `Localizable.strings` + Bundle.module? Murmur ships as a single
/// `swift build` / `xcodebuild` executable bundle and there's no
/// well-supported SPM-resource pipeline for the main app target that's
/// worth the complexity here. Two-language inline switch is cheaper,
/// readable, and trivially auditable.
///
/// The chosen language follows the system's preferred language list, not
/// any app-specific override. If macOS is set to Russian (or any "ru-*"
/// variant), Murmur's menu and status lines come out in Russian; anything
/// else falls through to English. Add a third language by extending
/// `currentLanguage` and adding a parameter to `t(...)`.

/// Returns `ru` when the user's preferred system language is Russian,
/// `en` otherwise. Used inline at call sites so each string keeps both
/// versions next to each other — easy to read, easy to keep in sync.
func t(_ en: String, ru: String) -> String {
    Localization.isRussian ? ru : en
}

enum Localization {
    /// Cached at first access — the system language doesn't change while
    /// the app is running. Reads `Locale.preferredLanguages.first`, which
    /// is what System Settings → General → Language & Region surfaces.
    static let isRussian: Bool = {
        guard let preferred = Locale.preferredLanguages.first?.lowercased() else {
            return false
        }
        return preferred.hasPrefix("ru")
    }()
}
