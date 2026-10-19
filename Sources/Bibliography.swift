import Foundation

struct BibliographyField: Identifiable {
    let name: String
    let value: String
    let range: NSRange
    let editable: Bool
    let wrapped: Bool
    let quoted: Bool
    var id: String { name }
    var label: String { Bibliography.labels[name] ?? name }
}

struct BibliographyEntry: Identifiable {
    let type: String
    let key: String
    let fields: [BibliographyField]
    let range: NSRange
    var id: String { "\(key):\(range.location)" }
    func value(_ name: String) -> String { fields.first { $0.name == name }.map { Bibliography.display($0.value) } ?? "" }
    var title: String { let title = value("title"); return title.isEmpty ? key : title }
    var authors: String { value("author").replacingOccurrences(of: " and ", with: " · ") }
    var publication: String { [value("journal"), value("booktitle"), value("publisher"), value("school")].first { !$0.isEmpty } ?? "" }
    var typeLabel: String { Bibliography.types[type] ?? type }
}

struct Bibliography {
    let entries: [BibliographyEntry]
    let hasUnparsedEntries: Bool
    static let labels = ["title":"Başlık", "author":"Yazarlar", "editor":"Editörler", "year":"Yıl", "month":"Ay", "journal":"Dergi", "booktitle":"Kitap / konferans", "publisher":"Yayınevi", "school":"Üniversite", "institution":"Kurum", "volume":"Cilt", "number":"Sayı", "pages":"Sayfalar", "edition":"Baskı", "address":"Yer", "doi":"DOI", "url":"Bağlantı", "howpublished":"Yayın / erişim", "note":"Not", "isbn":"ISBN", "issn":"ISSN", "eprint":"Ön baskı", "archiveprefix":"Arşiv", "abstract":"Özet", "keywords":"Anahtar kelimeler"]
    static let types = ["article":"Makale", "book":"Kitap", "inproceedings":"Konferans bildirisi", "conference":"Konferans bildirisi", "incollection":"Kitap bölümü", "inbook":"Kitap bölümü", "proceedings":"Bildiri kitabı", "phdthesis":"Doktora tezi", "mastersthesis":"Yüksek lisans tezi", "techreport":"Teknik rapor", "manual":"Kılavuz", "misc":"Diğer kaynak", "online":"Çevrimiçi kaynak", "software":"Yazılım", "dataset":"Veri seti", "unpublished":"Yayımlanmamış çalışma", "report":"Rapor"]

    init(_ text: String) {
        let reader = Reader(text)
        var entries: [BibliographyEntry] = [], incomplete = false
        var i = 0
        while i < reader.count {
            reader.skip(&i)
            guard i < reader.count else { break }
            guard reader.units[i] == 64 else { i += 1; continue }
            let start = i; i += 1
            let typeStart = i
            while i < reader.count, reader.isName(reader.units[i]) { i += 1 }
            let type = reader.string(typeStart, i).lowercased()
            reader.skip(&i)
            guard i < reader.count, [123, 40].contains(reader.units[i]), let end = reader.blockEnd(i) else {
                incomplete = true; i = min(reader.count, i + 1); continue
            }
            if ["comment", "preamble", "string"].contains(type) { i = end + 1; continue }
            var cursor = i + 1
            let keyStart = cursor
            while cursor < end, reader.units[cursor] != 44 { cursor += 1 }
            let key = reader.string(keyStart, cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            guard cursor < end, !key.isEmpty, !type.isEmpty else { incomplete = true; i = end + 1; continue }
            cursor += 1
            var fields: [BibliographyField] = [], valid = true
            while cursor < end {
                reader.skip(&cursor)
                if cursor < end, reader.units[cursor] == 44 { cursor += 1; continue }
                guard cursor < end else { break }
                let nameStart = cursor
                while cursor < end, reader.isName(reader.units[cursor]) { cursor += 1 }
                let name = reader.string(nameStart, cursor).lowercased()
                reader.skip(&cursor)
                guard !name.isEmpty, cursor < end, reader.units[cursor] == 61 else { valid = false; break }
                cursor += 1; reader.skip(&cursor)
                let valueStart = cursor
                let valueEnd = reader.valueEnd(cursor, limit: end)
                var trimmedEnd = valueEnd
                while trimmedEnd > valueStart, reader.isSpace(reader.units[trimmedEnd - 1]) { trimmedEnd -= 1 }
                let raw = reader.string(valueStart, trimmedEnd)
                let wrapped = (raw.hasPrefix("{") && reader.blockEnd(valueStart) == trimmedEnd - 1) || (raw.hasPrefix("\"") && reader.quotedEnd(valueStart) == trimmedEnd - 1)
                let numeric = !raw.isEmpty && raw.allSatisfy { $0.isNumber }
                let range = NSRange(location: valueStart + (wrapped ? 1 : 0), length: max(0, trimmedEnd - valueStart - (wrapped ? 2 : 0)))
                if fields.contains(where: { $0.name == name }) { valid = false; break }
                fields.append(BibliographyField(name: name, value: (text as NSString).substring(with: range), range: range, editable: wrapped || numeric, wrapped: wrapped, quoted: wrapped && raw.hasPrefix("\"")))
                cursor = valueEnd
            }
            if valid { entries.append(BibliographyEntry(type: type, key: key, fields: fields, range: NSRange(location: start, length: end + 1 - start))) }
            else { incomplete = true }
            i = end + 1
        }
        self.entries = entries
        hasUnparsedEntries = incomplete
    }

    /// Only replace explicitly edited literal values. Comments, directives and unknown fields stay byte-for-byte intact.
    static func replacing(_ entry: BibliographyEntry, in source: String, values: [String: String]) -> String {
        let result = NSMutableString(string: source)
        for field in entry.fields.sorted(by: { $0.range.location > $1.range.location }) {
            guard field.editable, let value = values[field.name], value != display(field.value) else { continue }
            let literal = encode(value)
            let escaped = field.quoted ? literal.replacingOccurrences(of: "\"", with: "{\"}") : literal
            result.replaceCharacters(in: field.range, with: field.wrapped ? escaped : "{\(escaped)}")
        }
        return result as String
    }

    static func display(_ raw: String) -> String {
        var value = raw
        // Literal special characters and common TeX accents, including nested surname accents.
        value = value.replacingOccurrences(of: #"(?:\\\\)+(?=\\["'`^~cvu=])"#, with: "", options: .regularExpression)
        for (tex, character) in [(#"\&"#, "&"), (#"\%"#, "%"), (#"\_"#, "_"), ("\\#", "#"), (#"\$"#, "$"), (#"\textasciitilde{}"#, "\u{E002}"), (#"\textasciicircum{}"#, "^"), (#"\textbackslash{}"#, "\u{E003}"), (#"\{"#, "\u{E000}"), (#"\}"#, "\u{E001}")] {
            value = value.replacingOccurrences(of: tex, with: character)
        }
        value = value.replacingOccurrences(of: #"\\(?:url|emph|textit|textbf|texttt)\s*\{"#, with: "{", options: .regularExpression)
        let accents: [(String, String)] = [("\"", "\u{0308}"), ("'", "\u{0301}"), ("`", "\u{0300}"), ("^", "\u{0302}"), ("~", "\u{0303}"), ("c", "\u{0327}"), ("v", "\u{030C}"), ("u", "\u{0306}"), ("=", "\u{0304}")]
        for (accent, mark) in accents {
            let argument = ["c", "v", "u"].contains(accent) ? #"(?:\s+\{?|\{)([A-Za-z])\}?"# : #"\s*\{?([A-Za-z])\}?"#
            let pattern = #"\\"# + NSRegularExpression.escapedPattern(for: accent) + argument
            if let expression = try? NSRegularExpression(pattern: pattern) {
                for match in expression.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length)).reversed() {
                    let base = (value as NSString).substring(with: match.range(at: 1))
                    value = (value as NSString).replacingCharacters(in: match.range, with: (base + mark).precomposedStringWithCanonicalMapping)
                }
            }
        }
        return value.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "").replacingOccurrences(of: "~", with: " ").replacingOccurrences(of: "\u{E000}", with: "{").replacingOccurrences(of: "\u{E001}", with: "}").replacingOccurrences(of: "\u{E002}", with: "~").replacingOccurrences(of: "\u{E003}", with: "\\").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func encode(_ text: String) -> String {
        var value = ""
        for character in text {
            switch character {
            case "\\": value += #"\textbackslash{}"#
            case "&", "%", "_", "#", "$", "{", "}": value += "\\" + String(character)
            case "~": value += #"\textasciitilde{}"#
            case "^": value += #"\textasciicircum{}"#
            default: value.append(character)
            }
        }
        return value
    }

    private final class Reader {
        let units: [UInt16]
        let source: NSString
        var count: Int { units.count }
        init(_ source: String) { self.source = source as NSString; units = Array(source.utf16) }
        func string(_ start: Int, _ end: Int) -> String { source.substring(with: NSRange(location: start, length: max(0, end - start))) }
        func isSpace(_ c: UInt16) -> Bool { [9, 10, 13, 32].contains(c) }
        func isName(_ c: UInt16) -> Bool { (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || [45, 95, 58].contains(c) }
        func skip(_ i: inout Int) {
            while i < count {
                if isSpace(units[i]) { i += 1 }
                else if units[i] == 37 { while i < count, units[i] != 10 { i += 1 } }
                else { break }
            }
        }
        func quotedEnd(_ start: Int) -> Int? {
            var i = start + 1, braces = 0
            while i < count {
                if units[i] == 92 { i += 2; continue }
                if units[i] == 123 { braces += 1 }
                if units[i] == 125 { braces -= 1 }
                if units[i] == 34 && braces == 0 { return i }
                i += 1
            }
            return nil
        }
        func blockEnd(_ start: Int) -> Int? {
            let close: UInt16 = units[start] == 40 ? 41 : 125
            var i = start + 1, braces = 0
            while i < count {
                let c = units[i]
                if c == 92 { i += 2; continue }
                if c == 34 && braces == 0 { guard let end = quotedEnd(i) else { return nil }; i = end + 1; continue }
                if c == close && braces == 0 { return i }
                if c == 123 { braces += 1 }
                if c == 125 { braces -= 1 }
                i += 1
            }
            return nil
        }
        func valueEnd(_ start: Int, limit: Int) -> Int {
            var i = start
            while i < limit {
                if units[i] == 123 { guard let end = blockEnd(i) else { return limit }; i = end + 1 }
                else if units[i] == 34 { guard let end = quotedEnd(i) else { return limit }; i = end + 1 }
                else if units[i] == 44 { return i }
                else if units[i] == 92 { i += 2 }
                else { i += 1 }
            }
            return limit
        }
    }
}
