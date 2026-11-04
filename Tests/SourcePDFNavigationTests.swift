import Foundation

@main struct SourcePDFNavigationChecks {
    static func main() {
        func locate(_ phrase: String, source: String, pages: [String], backwards: Bool = false, preferred: Int? = nil) -> PDFSourceNavigation.PDFPageLocation? {
            let range = (source as NSString).range(of: phrase, options: backwards ? .backwards : [])
            precondition(range.location != NSNotFound)
            return PDFSourceNavigation.PDFIndex(pages: pages).locate(source: source, range: range, preferredPageIndex: preferred)
        }
        let source = "🎵\n\\section{Introduction}\nAudio \\emph{features} describe a song.\n% hidden comment\n\\label{notprinted}\nArtist history helps."
        let pages = ["Contents Introduction 1", "Introduction\nAudio features describe a song. Artist history helps."]
        let hit = locate("Audio \\emph{features}", source: source, pages: pages)!
        assert(hit.pageIndex == 1)
        assert((pages[1] as NSString).substring(with: hit.range) == "Audio features")
        assert(locate("Introduction", source: source, pages: pages)?.pageIndex == 1)
        assert(locate("hidden comment", source: source, pages: pages) == nil)
        assert(locate("notprinted", source: source, pages: pages) == nil)
        assert(locate("emph", source: source, pages: pages) == nil)
        let typography = "The final classification uses ŞARKI özellikleri."
        let printed = ["The ﬁnal classi-\nfication uses şarkı özellikleri."]
        assert(locate("final classification", source: typography, pages: printed) != nil)
        assert(locate("ŞARKI özellikleri", source: typography, pages: printed) != nil)
        let repeated = "One model handles audio. Another model uses lyrics."
        let second = locate("model", source: repeated, pages: [repeated], backwards: true)!
        assert(second.range == (repeated as NSString).range(of: "model", options: .backwards))
        assert(locate("model", source: "model", pages: ["model", "model"]) == nil)
        assert(locate("model", source: "model", pages: ["models"]) == nil)
        assert(locate("i", source: "i", pages: ["i"]) == nil)
        assert(locate("new unsaved wording", source: "new unsaved wording", pages: ["old text"]) == nil)
        let cover = "\\newcommand{\\Title}{Hit Song Prediction}\n\\newcommand{\\Student}{Ada EXAMPLE}"
        assert(locate("Hit Song Prediction", source: cover, pages: ["Hit Song Prediction Ada EXAMPLE", "Hit Song Prediction"], preferred: 0)?.pageIndex == 0)
        let index = PDFSourceNavigation.PDFIndex(pages: pages)
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: 0), NSRange(location: 99999, length: 1), NSRange(location: 0, length: Int.max)] {
            assert(index.locate(source: source, range: range) == nil)
        }
        let long = (0..<200).map { "word\($0)" }.joined(separator: " ")
        assert(locate(long, source: long, pages: [long]) != nil)
        // A source selection spanning a citation still reaches the PDF text around the printed number.
        let cited = "The promotion budget~\\cite{key}. Studies can also help."
        let citedPage = "The promotion budget [1]. Studies can also help."
        let citedHit = locate(cited, source: cited, pages: [citedPage])
        assert(citedHit.map { (citedPage as NSString).substring(with: $0.range) } == "The promotion budget [1]. Studies can also help")
        // PDF find bar: every occurrence, Turkish folding, wrapped and hyphenated words, no false joins.
        let findPages = ["FİNAL raporunda güncellenecek. Final\nrapor bitti.", "not her par-\nticular word, another word"]
        let find = PDFSourceNavigation.PDFIndex(pages: findPages)
        func found(_ query: String) -> [String] { find.matches(query).map { (findPages[$0.pageIndex] as NSString).substring(with: $0.range) } }
        assert(found("final") == ["FİNAL", "Final"])
        assert(found("guncellenecek") == ["güncellenecek"])
        assert(found("final rapor") == ["FİNAL raporunda", "Final\nrapor"])
        assert(found("particular") == ["par-\nticular"])
        assert(found("the") == ["another"])
        assert(found("word") == ["word", "word"])
        assert(found("  ").isEmpty && found("zzz").isEmpty)
        assert(find.matches("word").map(\.pageIndex) == [1, 1])
        print("PASS: source-to-PDF mapping, original PDF ranges, source markup/comments, Unicode/ligatures/wrapping, repeated occurrences, cover priority, stale PDF, ambiguity and invalid ranges.")
    }
}
