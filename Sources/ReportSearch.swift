import Foundation

struct TextMatch: Identifiable {
    let line: Int
    let excerpt: String
    let range: NSRange
    let score: Double
    var id: String { "\(range.location):\(range.length)" }
}

enum ReportSearch {
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func tokens(_ text: String) -> [(String, NSRange)] {
        let expression = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_]+"#)
        let ns = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (normalized(ns.substring(with: $0.range)), $0.range)
        }
    }

    static func tokenScore(_ query: String, _ candidate: String) -> Double {
        if query == candidate { return 1 }
        if candidate.hasPrefix(query) { return 0.88 }
        if candidate.contains(query) { return 0.76 }
        // Keep short queries precise; tolerate a typo from four letters onward.
        let limit = query.count >= 7 ? 2 : query.count >= 4 ? 1 : 0
        guard limit > 0, abs(query.count - candidate.count) <= limit else { return 0 }
        let distance = editDistance(query, candidate)
        return distance <= limit ? 0.68 - Double(distance - 1) * 0.1 : 0
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let left = Array(a), right = Array(b)
        var previous = Array(0...right.count)
        var previousPrevious: [Int]?
        for (i, char) in left.enumerated() {
            var current = [i + 1]
            for (j, other) in right.enumerated() {
                var distance = min(current[j] + 1, previous[j + 1] + 1, previous[j] + (char == other ? 0 : 1))
                if i > 0, j > 0, char == right[j - 1], left[i - 1] == other, let older = previousPrevious {
                    distance = min(distance, older[j - 1] + 1)
                }
                current.append(distance)
            }
            previousPrevious = previous
            previous = current
        }
        return previous.last ?? left.count
    }

    static func score(query: String, in text: String) -> Double {
        let wanted = tokens(query).map(\.0)
        let words = tokens(text).map(\.0)
        guard !wanted.isEmpty else { return 0 }
        let scores = wanted.map { q in words.map { tokenScore(q, $0) }.max() ?? 0 }
        // Every query term must have a plausible match; partial multi-term matches are noise.
        guard scores.allSatisfy({ $0 > 0 }) else { return 0 }
        return scores.reduce(0, +) / Double(scores.count)
    }

    static func matches(query: String, in text: String) -> [TextMatch] {
        let wanted = tokens(query).map(\.0)
        guard !wanted.isEmpty else { return [] }
        let ns = text as NSString
        var offset = 0, lineNumber = 1
        var result: [TextMatch] = []
        while offset < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
            let line = ns.substring(with: lineRange)
            let words = tokens(line)
            let scores = wanted.map { q in words.map { tokenScore(q, $0.0) }.max() ?? 0 }
            if scores.allSatisfy({ $0 > 0 }) {
                let lineScore = scores.reduce(0, +) / Double(scores.count)
                if wanted.count == 1 {
                    // Each occurrence is navigable, even when a line repeats the word.
                    for (word, range) in words {
                        let score = tokenScore(wanted[0], word)
                        if score > 0 {
                            let absolute = NSRange(location: lineRange.location + range.location, length: range.length)
                            result.append(TextMatch(line: lineNumber, excerpt: excerpt(line, around: range), range: absolute, score: score))
                        }
                    }
                } else {
                    let ranges = wanted.compactMap { q in words.max(by: { tokenScore(q, $0.0) < tokenScore(q, $1.0) })?.1 }
                    if let first = ranges.min(by: { $0.location < $1.location }), let end = ranges.map({ NSMaxRange($0) }).max() {
                        let range = NSRange(location: first.location, length: end - first.location)
                        result.append(TextMatch(line: lineNumber, excerpt: excerpt(line, around: range), range: NSRange(location: lineRange.location + range.location, length: range.length), score: lineScore))
                    }
                }
            }
            offset = NSMaxRange(lineRange)
            lineNumber += 1
        }
        return result.sorted { $0.score == $1.score ? $0.range.location < $1.range.location : $0.score > $1.score }
    }

    private static func excerpt(_ line: String, around range: NSRange) -> String {
        // Work in Swift character boundaries so snippets never split an emoji/surrogate pair.
        guard let swiftRange = Range(range, in: line) else { return line.trimmingCharacters(in: .whitespacesAndNewlines) }
        let start = line.index(swiftRange.lowerBound, offsetBy: -20, limitedBy: line.startIndex) ?? line.startIndex
        let end = line.index(swiftRange.upperBound, offsetBy: 65, limitedBy: line.endIndex) ?? line.endIndex
        return (start == line.startIndex ? "" : "…") + line[start..<end].trimmingCharacters(in: .whitespacesAndNewlines) + (end == line.endIndex ? "" : "…")
    }
}
