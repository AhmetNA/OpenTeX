import Foundation

struct PDFSourceDocument {
    let path: String
    let text: String
}

struct PDFSourceLocation {
    let path: String
    let range: NSRange
}

/// Text-based reverse navigation; original UTF-16 ranges always point into the editable source.
/// Context on both sides disambiguates repeated words without guessing from the open editor.
enum PDFSourceNavigation {
    private struct NormalizedText {
        let text: NSString
        let ranges: [NSRange]

        init(_ original: String, latex: Bool) {
            let cleaned = NSMutableString(string: original)
            if latex {
                // Hide comments, non-rendered arguments and command names, preserving source offsets.
                for pattern in [#"(?m)(?<!\\)%[^\n]*"#,
                                #"\\\\\*?(?:\[[^\]]*\])?"#,
                                #"\\(?:label|cite\w*|ref|eqref|pageref|bibliography|bibliographystyle|input|include|begin|end)\*?(?:\[[^\]]*\])?\{[^{}]*\}"#,
                                #"\\[a-zA-Z@]+\*?"#] {
                    let expression = try! NSRegularExpression(pattern: pattern)
                    for match in expression.matches(in: cleaned as String, range: NSRange(location: 0, length: cleaned.length)).reversed() {
                        cleaned.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
                    }
                }
            }
            let words = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
            var value = "", positions: [NSRange] = []
            for match in words.matches(in: cleaned as String, range: NSRange(location: 0, length: cleaned.length)) {
                let word = ReportSearch.normalized(cleaned.substring(with: match.range).precomposedStringWithCompatibilityMapping)
                value += word
                positions.append(contentsOf: repeatElement(match.range, count: (word as NSString).length))
            }
            text = value as NSString
            ranges = positions
        }

        func sourceRange(_ match: NSRange) -> NSRange {
            let first = ranges[match.location], last = ranges[NSMaxRange(match) - 1]
            return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        }
    }

    static func locate(selection: String, pageText: String, pageRange: NSRange,
                       documents: [PDFSourceDocument], preferredPath: String? = nil) -> PDFSourceLocation? {
        let query = NormalizedText(selection, latex: false).text
        guard query.length > 0 else { return nil }
        let page = NormalizedText(pageText, latex: false)
        let beforeEnd = page.ranges.firstIndex { NSMaxRange($0) > pageRange.location } ?? page.ranges.count
        let afterStart = page.ranges.firstIndex { $0.location >= NSMaxRange(pageRange) } ?? page.ranges.count
        let before = page.text.substring(with: NSRange(location: max(0, beforeEnd - 120), length: min(120, beforeEnd)))
        let after = page.text.substring(with: NSRange(location: afterStart, length: min(120, page.text.length - afterStart)))
        var candidates: [(PDFSourceLocation, Int)] = []
        for document in documents {
            let source = NormalizedText(document.text, latex: true)
            var start = 0
            while start < source.text.length {
                let hit = source.text.range(of: query as String, range: NSRange(location: start, length: source.text.length - start))
                guard hit.location != NSNotFound else { break }
                let left = source.text.substring(with: NSRange(location: max(0, hit.location - 120), length: min(120, hit.location)))
                let end = NSMaxRange(hit)
                let right = source.text.substring(with: NSRange(location: end, length: min(120, source.text.length - end)))
                let score = commonPrefix(before.reversed(), left.reversed()) + commonPrefix(after, right)
                candidates.append((PDFSourceLocation(path: document.path, range: source.sourceRange(hit)), score))
                start = hit.location + 1
            }
        }
        // A known cover page should resolve editable cover fields before repeated body text.
        if let preferredPath, candidates.contains(where: { $0.0.path == preferredPath }) {
            candidates = candidates.filter { $0.0.path == preferredPath }
        }
        candidates.sort { $0.1 > $1.1 }
        guard let best = candidates.first else { return nil }
        // A tie or an isolated one-letter match is not a reliable source destination.
        if candidates.count > 1 && best.1 <= candidates[1].1 { return nil }
        if query.length < 3 && best.1 < 8 { return nil }
        return best.0
    }

    struct PDFPageLocation: Equatable {
        let pageIndex: Int
        let range: NSRange
    }

    struct RevealRequest {
        let id = UUID()
        let source: String
        let range: NSRange
        let preferredPageIndex: Int?
    }

    /// Cached per PDF document. Selection ranges always address PDFKit's original page strings.
    struct PDFIndex {
        private let pages: [NormalizedText]
        init(pages: [String]) { self.pages = pages.map { NormalizedText($0, latex: false) } }

        func locate(source text: String, range: NSRange, preferredPageIndex: Int? = nil) -> PDFPageLocation? {
            guard range.location != NSNotFound, range.location >= 0, range.length > 0,
                  range.location <= (text as NSString).length, range.length <= (text as NSString).length - range.location else { return nil }
            let source = NormalizedText(text, latex: true)
            guard let start = source.ranges.firstIndex(where: { NSIntersectionRange($0, range).length > 0 }),
                  let last = source.ranges.lastIndex(where: { NSIntersectionRange($0, range).length > 0 }) else { return nil }
            // A long selection reveals its opening passage, avoiding a query longer than a PDF page.
            var end = min(last + 1, start + 180)
            while end > start, end < source.ranges.count, source.ranges[end - 1] == source.ranges[end] { end -= 1 }
            if end == start {
                end = start + 1
                while end < source.ranges.count, source.ranges[end - 1] == source.ranges[end] { end += 1 }
            }
            let query = source.text.substring(with: NSRange(location: start, length: end - start))
            let before = source.text.substring(with: NSRange(location: max(0, start - 120), length: min(120, start)))
            let after = source.text.substring(with: NSRange(location: end, length: min(120, source.text.length - end)))
            var candidates: [(PDFPageLocation, Int)] = []
            for (index, page) in pages.enumerated() {
                var cursor = 0
                while cursor < page.text.length {
                    let hit = page.text.range(of: query, range: NSRange(location: cursor, length: page.text.length - cursor))
                    guard hit.location != NSNotFound else { break }
                    cursor = hit.location + 1
                    let upper = NSMaxRange(hit)
                    // Do not resolve a selected word to a fragment of a different word.
                    guard hit.location == 0 || page.ranges[hit.location - 1] != page.ranges[hit.location],
                          upper == page.ranges.count || page.ranges[upper - 1] != page.ranges[upper] else { continue }
                    let left = page.text.substring(with: NSRange(location: max(0, hit.location - 120), length: min(120, hit.location)))
                    let right = page.text.substring(with: NSRange(location: upper, length: min(120, page.text.length - upper)))
                    let score = commonPrefix(before.reversed(), left.reversed()) + commonPrefix(after, right)
                    candidates.append((PDFPageLocation(pageIndex: index, range: page.sourceRange(hit)), score))
                }
            }
            if let preferredPageIndex, candidates.contains(where: { $0.0.pageIndex == preferredPageIndex }) {
                candidates = candidates.filter { $0.0.pageIndex == preferredPageIndex }
            }
            candidates.sort { $0.1 > $1.1 }
            guard let best = candidates.first else { return nil }
            if candidates.count > 1 && best.1 <= candidates[1].1 { return nil }
            if query.count < 3 && best.1 < 8 { return nil }
            return best.0
        }
    }

    private static func commonPrefix<A: Sequence, B: Sequence>(_ a: A, _ b: B) -> Int where A.Element == Character, B.Element == Character {
        zip(a, b).prefix { $0 == $1 }.count
    }
}
