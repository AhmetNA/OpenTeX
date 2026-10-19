import AppKit
import Foundation
import PDFKit

@main struct AppChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let store = ReportStore()
        let intro = store.files.first { $0.path == "sections/01-introduction.tex" }!
        let analysis = store.files.first { $0.path == "sections/02-analysis.tex" }!
        assert(store.selected == intro)
        store.edited(store.text + "\n% Draft before a single file switch\n")
        store.select(analysis)
        assert(store.selected == analysis && store.text.contains("Rust compiler"))
        let saved = try String(contentsOf: store.root.appendingPathComponent("report/" + intro.path), encoding: .utf8)
        assert(saved.contains("Draft before a single file switch"))
        store.toggleSidebar(); assert(!store.sidebarVisible)
        store.toggleSidebar(); assert(store.sidebarVisible && store.selected == analysis)
        store.searchQuery = "rust"
        store.searchNow()
        assert(store.searchResults.count == 2 && store.matchCount == 3)
        assert(store.searchResults[0].score >= store.searchResults[1].score)
        let result = store.searchResults.first { $0.file == intro }!
        store.openMatch(result, result.matches[1])
        assert(store.selected == intro)
        assert((store.text as NSString).substring(with: store.jumpRange!) == "Rust")
        let firstID = store.activeMatchID
        store.nextMatch(); assert(store.activeMatchID != firstID)
        store.nextMatch(backward: true); assert(store.activeMatchID == firstID)
        store.searchQuery = "rusr"; store.searchNow()
        assert(store.searchResults.count == 2)
        // A single native button action must select immediately. Blank trailing space is clickable.
        let row = FileRowButton(frame: NSRect(x: 0, y: 0, width: 260, height: 51))
        row.isBordered = false; row.setButtonType(.momentaryChange)
        assert(row.acceptsFirstMouse(for: nil))
        assert(row.hitTest(NSPoint(x: 250, y: 25)) === row)
        var actions = 0
        let handler = FileRow.Coordinator { actions += 1; store.select(analysis) }
        row.target = handler; row.action = #selector(FileRow.Coordinator.invoke)
        row.performClick(nil)
        assert(actions == 1 && store.selected == analysis)
        // An unchanged query must observe an agent editing an unselected file directly.
        store.select(analysis)
        store.searchQuery = "externalkeyword"
        store.searchNow()
        assert(store.matchCount == 0)
        try "externalkeyword arrived\n".write(to: store.root.appendingPathComponent("report/" + intro.path), atomically: true, encoding: .utf8)
        store.checkExternalChanges()
        assert(store.searchPending)
        store.searchNow()
        assert(store.matchCount == 1 && store.searchResults[0].file == intro)
        try "no occurrence anymore\n".write(to: store.root.appendingPathComponent("report/" + intro.path), atomically: true, encoding: .utf8)
        store.checkExternalChanges()
        assert(store.searchPending)
        store.searchNow()
        assert(store.matchCount == 0)
        // Native PDFKit selection -> callback -> file switch -> source range, using temporary files only.
        try "\\newcommand{\\RaporBaslik}{Hit Song Prediction\\\\[4pt] from Audio Features\\\\[4pt] and Artist History}\n\\newcommand{\\RaporOgrenci}{Ada EXAMPLE}\n\\renewcommand{\\txtAyYil}{October 2026}".write(to: store.root.appendingPathComponent("report/metadata.tex"), atomically: true, encoding: .utf8)
        store.scan()
        let metadata = store.files.first { $0.path == "metadata.tex" }!
        let pdfSource = "Audio \\emph{features} describe a song. Artist history helps."
        try pdfSource.write(to: store.root.appendingPathComponent("report/" + intro.path), atomically: true, encoding: .utf8)
        store.select(analysis)
        store.edited(store.text + " Saved while navigating from PDF.")
        store.sidebarVisible = false
        let bytes = NSMutableData()
        let consumer = CGDataConsumer(data: bytes as CFMutableData)!
        var bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
        let pdfContext = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        func drawPage(_ text: String) {
            pdfContext.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: pdfContext, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            (text as NSString).draw(at: NSPoint(x: 20, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
            NSGraphicsContext.restoreGraphicsState()
            pdfContext.endPDFPage()
        }
        drawPage("Hit Song Prediction\nfrom Audio Features\nand Artist History\nAda EXAMPLE\nOctober 2026")
        drawPage("Audio features describe a song. Artist history helps.")
        pdfContext.closePDF()
        let pdf = PDFDocument(data: bytes as Data)!
        let page = pdf.page(at: 1)!
        let preview = PreviewPDFView()
        preview.document = pdf
        var callbacks = 0
        let coordinator = PDFPreview.Coordinator { selection, pageText, range, isCover in
            callbacks += 1
            store.openPDFSelection(selection, pageText: pageText, pageRange: range, isCover: isCover)
        }
        coordinator.observe(preview)
        let selectedRange = (page.string! as NSString).range(of: "features")
        preview.currentSelection = page.selection(for: selectedRange)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: preview)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        assert(callbacks == 1 && store.selected == intro && store.sidebarVisible && store.searchQuery.isEmpty)
        assert((store.text as NSString).substring(with: store.jumpRange!) == "features")
        let savedDuringNavigation = try String(contentsOf: store.root.appendingPathComponent("report/" + analysis.path), encoding: .utf8)
        assert(savedDuringNavigation.contains("Saved while navigating"))
        let textEditor = NSTextView()
        textEditor.string = store.text
        CodeEditor.Coordinator(store).reveal(store.jumpRange!, in: textEditor)
        assert(textEditor.selectedRange() == store.jumpRange!)
        // No match leaves the current file and draft untouched. Observer removal cancels queued navigation.
        store.openPDFSelection("outdated PDF text", pageText: "outdated PDF text", pageRange: NSRange(location: 0, length: 17))
        assert(store.selected == intro && store.text == pdfSource)
        // A cover title/name/date must route through the native callback to editable metadata.
        let coverPage = pdf.page(at: 0)!
        for phrase in ["Hit Song Prediction", "from Audio Features", "Ada", "EXAMPLE", "October"] {
            let range = (coverPage.string! as NSString).range(of: phrase)
            assert(range.location != NSNotFound)
            preview.currentSelection = coverPage.selection(for: range)
            coordinator.openSelection()
            assert(store.selected == metadata && !metadata.isProtected)
            assert((store.text as NSString).substring(with: store.jumpRange!).contains(phrase))
        }
        let callbacksBeforeStop = callbacks
        preview.currentSelection = page.selection(for: NSRange(location: 0, length: 5))
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: preview)
        coordinator.stopObserving()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        assert(callbacks == callbacksBeforeStop)
        let protected = store.files.first { $0.path == "preamble.tex" }!
        store.select(protected)
        let frozenText = store.text
        store.edited("must never replace the template")
        assert(store.text == frozenText && !store.dirty)
        assert(!store.files.contains(where: { $0.path.contains("Original.tex") }))
        // Structured bibliography editing uses the same draft/save/conflict path as source editing.
        let bibText = "@article{example, title={Original title}, year={2026}, custom={Keep this}}"
        try bibText.write(to: store.root.appendingPathComponent("report/kaynaklar.bib"), atomically: true, encoding: .utf8)
        store.scan()
        let bibFile = store.files.first { $0.path == "kaynaklar.bib" }!
        store.select(bibFile)
        let bibEntry = Bibliography(store.text).entries[0]
        assert(store.editBibliography(bibEntry, original: bibText, values: ["title":"Edited & readable"]) == nil)
        assert(store.dirty && Bibliography(store.text).entries[0].title == "Edited & readable")
        assert(store.text.contains("custom={Keep this}"))
        let currentBib = store.text
        assert(store.editBibliography(bibEntry, original: bibText, values: ["title":"Stale edit"]) != nil)
        assert(store.text == currentBib)
        assert(store.save())
        store.conflict = true
        assert(store.editBibliography(Bibliography(store.text).entries[0], original: store.text, values: ["title":"Conflict edit"]) != nil)
        assert(store.text == currentBib)
        store.conflict = false
        store.select(analysis)
        // Never switch away by discarding an unresolved draft.
        store.edited(store.text + "\nlocal conflict draft")
        try "external conflict version".write(to: store.fileURL!, atomically: true, encoding: .utf8)
        store.select(intro)
        assert(store.selected == analysis && store.conflict && store.text.contains("local conflict draft"))
        store.openPDFSelection("features", pageText: "Audio features describe a song.", pageRange: NSRange(location: 6, length: 8))
        assert(store.selected == analysis && store.conflict && store.text.contains("local conflict draft"))
        print("PASS: one native click, blank row hit area, inactive-window first-click acceptance, synchronous file switch/save, sidebar toggle, grouped content search, range navigation, typo match, PDFKit selection notification and source navigation, editor selection, conflict protection.")
    }
}
