import Foundation

@main struct PDFNavigationChecks {
    static func main() {
        func find(_ selected: String, page: String, sources: [PDFSourceDocument]) -> PDFSourceLocation? {
            let range = (page as NSString).range(of: selected)
            precondition(range.location != NSNotFound)
            return PDFSourceNavigation.locate(selection: selected, pageText: page, pageRange: range, documents: sources)
        }
        let original = "🎵\n\\section{Introduction}\nAudio \\emph{features} describe a song.\n% hidden uniquecomment\n\\label{uniqueidentifier}\nArtist history helps."
        let source = PDFSourceDocument(path: "intro.tex", text: original)
        let result = find("Audio features", page: "Audio features describe a song.", sources: [source])!
        assert(result.path == "intro.tex")
        assert((original as NSString).substring(with: result.range) == "Audio \\emph{features")
        // PDF ligatures, accents, wrapped hyphens and source markup retain valid original ranges.
        let text = "The final classification uses ŞARKI özellikleri and \\textbf{artist history}."
        let doc = PDFSourceDocument(path: "design.tex", text: text)
        assert(find("ﬁnal classiﬁcation", page: "The ﬁnal classiﬁcation uses music.", sources: [doc]) != nil)
        assert(find("classi-\nfication", page: "The final classi-\nfication uses music.", sources: [doc]) != nil)
        assert(find("şarkı özellikleri", page: "şarkı özellikleri and artist history", sources: [doc]) != nil)
        assert(find("artist history", page: "and artist history", sources: [doc]) != nil)
        assert(find("uniquecomment", page: "uniquecomment", sources: [source]) == nil)
        assert(find("uniqueidentifier", page: "uniqueidentifier", sources: [source]) == nil)
        assert(find("unrelated content", page: "unrelated content", sources: [source]) == nil)
        let first = PDFSourceDocument(path: "first.tex", text: "The training model learns from older songs.")
        let second = PDFSourceDocument(path: "second.tex", text: "The final model estimates later chart success.")
        let word = find("model", page: second.text, sources: [first, second])!
        assert(word.path == second.path && (second.text as NSString).substring(with: word.range) == "model")
        assert(find("model", page: "model", sources: [first, second]) == nil)
        // The actual selected occurrence on a page matters, not the first occurrence of its word.
        let repeated = "One model handles audio. Another model uses lyrics."
        let range = (repeated as NSString).range(of: "model", options: .backwards)
        let hit = PDFSourceNavigation.locate(selection: "model", pageText: repeated, pageRange: range,
            documents: [PDFSourceDocument(path: "repeated.tex", text: repeated)])!
        assert(hit.range == range)
        assert(find("i", page: "i", sources: [PDFSourceDocument(path: "one.tex", text: "i")]) == nil)
        let cover = PDFSourceDocument(path: "metadata.tex", text: "\\newcommand{\\RaporBaslik}{Hit Song Prediction\\\\[4pt] from Audio Features\\\\[4pt] and Artist History}\n\\newcommand{\\RaporOgrenci}{Ada EXAMPLE}\n\\renewcommand{\\txtAyYil}{October 2026}")
        let body = PDFSourceDocument(path: "body.tex", text: "Hit song prediction is studied in October 2026.")
        let coverPage = "YILDIZ TECHNICAL UNIVERSITY\nHit Song Prediction\nfrom Audio Features\nand Artist History\nAda EXAMPLE\nOctober 2026"
        for selection in ["Hit Song Prediction", "Hit Song Prediction\nfrom Audio Features\nand Artist History", "Ada", "Ada EXAMPLE", "EXAMPLE", "October", "2026"] {
            let range = (coverPage as NSString).range(of: selection)
            let hit = PDFSourceNavigation.locate(selection: selection, pageText: coverPage, pageRange: range,
                documents: [body, cover], preferredPath: "metadata.tex")
            assert(hit?.path == "metadata.tex", "Cover destination missing: \(selection)")
            assert(NSMaxRange(hit!.range) <= (cover.text as NSString).length)
        }
        print("PASS: PDF reverse navigation: source offsets, LaTeX markup/comments, ligatures, wrapped words, Turkish, contextual repeated words and ambiguity.")
    }
}
