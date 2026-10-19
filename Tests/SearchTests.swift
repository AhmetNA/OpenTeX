import Foundation

@main struct SearchChecks {
    static func main() {
        let text = "Önsöz 🎵\nRust is fast. Rust also has ownership.\nA Ruts compiler example.\nNo relevant content here.\n"
        let hits = ReportSearch.matches(query: "rust", in: text)
        assert(hits.count == 3)
        assert(hits[2].score < hits[0].score)
        assert(ReportSearch.matches(query: "rsut", in: "Rust").count == 1)
        assert(hits[0].score == 1 && hits[1].score == 1)
        assert(hits[0].line == 2 && hits[1].line == 2)
        assert(hits[0].range.location != hits[1].range.location)
        let ns = text as NSString
        for h in hits.prefix(2) { assert(ns.substring(with: h.range) == "Rust") }
        assert(ReportSearch.score(query: "sarki", in: "ŞARKI") == 1)
        assert(ReportSearch.score(query: "giris", in: "GİRİŞ") == 1)
        assert(ReportSearch.matches(query: "", in: text).isEmpty)
        assert(ReportSearch.matches(query: " ", in: text).isEmpty)
        assert(ReportSearch.matches(query: "unrelatedzzzzz", in: text).isEmpty)
        assert(ReportSearch.score(query: "rust ownership", in: "Rust has ownership") == 1)
        assert(ReportSearch.score(query: "rust ownership", in: "Ownership alone") == 0)
        let partial = ReportSearch.matches(query: "comp", in: "compiler construction")
        assert(partial.count == 1 && partial[0].score < 1)
        let typo = ReportSearch.matches(query: "artisy", in: "artist history")
        assert(typo.count == 1 && typo[0].score > 0 && typo[0].score < 1)
        assert(ReportSearch.matches(query: "rust", in: "last line Rust").first?.line == 1)
        print("PASS: ranking, case/Turkish normalization, partial and typo matches, multi-term coverage, repeated occurrences, UTF-16 locations, empty/unrelated queries.")
    }
}
