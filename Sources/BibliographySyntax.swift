import AppKit

/// Highlight BibTeX structure without changing the underlying document text.
@MainActor enum BibliographySyntax {
    static func apply(to storage: NSTextStorage, fontSize: CGFloat) {
        let source = storage.string
        let document = Bibliography(source)
        let emphasis = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let header = try! NSRegularExpression(pattern: #"(@[A-Za-z]+)\s*[\{(]\s*([^,\s]+)"#)
        for entry in document.entries {
            if let match = header.firstMatch(in: source, range: entry.range) {
                storage.addAttributes([.foregroundColor: NSColor.systemPurple, .font: emphasis], range: match.range(at: 1))
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: match.range(at: 2))
            }
            for field in entry.fields {
                storage.addAttributes([.foregroundColor: NSColor.systemTeal, .font: emphasis], range: field.nameRange)
                switch field.name {
                case "title": storage.addAttributes([.foregroundColor: NSColor.systemIndigo, .font: emphasis], range: field.range)
                case "year", "month", "volume", "number", "pages": storage.addAttribute(.foregroundColor, value: NSColor.systemBrown, range: field.range)
                case "url", "doi": storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: field.range)
                default: break
                }
            }
        }
        // Keep partially typed field names recognizable while a record is incomplete.
        if document.hasUnparsedEntries {
            let fields = try! NSRegularExpression(pattern: #"(?m)^\s*([A-Za-z][A-Za-z0-9_-]*)\s*="#)
            for match in fields.matches(in: source, range: NSRange(location: 0, length: storage.length)) {
                storage.addAttributes([.foregroundColor: NSColor.systemTeal, .font: emphasis], range: match.range(at: 1))
            }
        }
    }
}
