import Foundation

@main struct LocalizationTests {
    static func main() throws {
        for identifier in ["tr", "tr-TR", "tr_TR", "TR-tr", "tr-Latn-TR"] {
            assert(AppLanguage.resolve([identifier]) == .turkish)
        }
        for identifiers in [["en-US"], ["en-TR", "tr-TR"], ["de-DE", "tr-TR"], ["fr-FR"], ["ja-JP"], []] {
            assert(AppLanguage.resolve(identifiers) == .english)
        }
        let resources = Bundle(path: CommandLine.arguments[1])!
        let english = AppLocalization(preferredLanguages: ["en-TR", "tr-TR"], resources: resources)
        let turkish = AppLocalization(preferredLanguages: ["tr-TR"], resources: resources)
        let fallback = AppLocalization(preferredLanguages: ["de-DE", "tr-TR"], resources: resources)
        assert(english.string("Ready") == "Ready")
        assert(turkish.string("Ready") == "Hazır")
        assert(turkish.string("Open Project") == "Proje Aç")
        assert(turkish.string("Title") == "Başlık")
        assert(fallback.string("Title") == "Title")
        assert(turkish.string("Unknown BibTeX field") == "Unknown BibTeX field")
        // Check every translation, including format argument order/types and dynamically named BibTeX fields.
        func catalog(_ language: String) throws -> [String: String] {
            let url = resources.url(forResource: language, withExtension: "lproj")!.appendingPathComponent("Localizable.strings")
            return try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: String]
        }
        let en = try catalog("en"), tr = try catalog("tr")
        assert(en.keys.sorted() == tr.keys.sorted() && en.count > 150)
        let format = try NSRegularExpression(pattern: "%[@d]")
        func arguments(_ value: String) -> [String] {
            format.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length)).map { (value as NSString).substring(with: $0.range) }
        }
        for (key, value) in en {
            assert(value == key && !tr[key]!.isEmpty)
            assert(arguments(key) == arguments(tr[key]!), key)
            assert(english.string(key) == value && fallback.string(key) == value)
            assert(turkish.string(key) == tr[key], key)
        }
        print("PASS: primary system language, regional variants, unsupported/empty English fallback, complete bilingual catalogs and format arguments.")
    }
}
