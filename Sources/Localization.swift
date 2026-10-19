import Foundation

enum AppLanguage: String {
    case english = "en"
    case turkish = "tr"

    /// Respect the primary system language. Unsupported languages always fall back to English,
    /// even if Turkish appears later in the user's preferred-language list.
    static func resolve(_ preferredLanguages: [String]) -> AppLanguage {
        let primary = preferredLanguages.first?.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first?.lowercased()
        return primary == "tr" ? .turkish : .english
    }
}

struct AppLocalization {
    let language: AppLanguage
    private let bundle: Bundle?

    init(preferredLanguages: [String], resources: Bundle = .main) {
        language = AppLanguage.resolve(preferredLanguages)
        bundle = resources.url(forResource: language.rawValue, withExtension: "lproj").flatMap(Bundle.init(url:))
    }

    func string(_ key: String) -> String {
        bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    static let current = AppLocalization(preferredLanguages: Locale.preferredLanguages)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let localized = AppLocalization.current.string(key)
    return arguments.isEmpty ? localized : String(format: localized, locale: Locale(identifier: AppLocalization.current.language.rawValue), arguments: arguments)
}
