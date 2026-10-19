import SwiftUI
import AppKit
import PDFKit
import Combine

struct ReportFile: Identifiable, Hashable {
    let path: String
    let title: String
    let hint: String
    let group: String
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var isProtected: Bool { ["cover.tex", "preamble.tex"].contains(path) }
    var isImage: Bool { ["png", "jpg", "jpeg", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
}

struct FileSearchResult: Identifiable {
    let file: ReportFile
    let matches: [TextMatch]
    let score: Double
    var id: String { file.id }
}

@MainActor
final class ReportStore: ObservableObject {
    @Published var root: URL
    @Published var files: [ReportFile] = []
    @Published var selected: ReportFile?
    @Published var text = ""
    @Published var dirty = false
    @Published var conflict = false
    @Published var busy = false
    @Published var status = "Hazır"
    @Published var error: String?
    @Published var log = ""
    @Published var showLog = false
    @Published var pdfRevision = 0
    @Published var autoCompile = false
    @Published var fontSize: CGFloat = 14
    @Published var sidebarVisible = true
    @Published var searchQuery = "" { didSet { scheduleSearch() } }
    @Published var searchResults: [FileSearchResult] = []
    @Published var searchPending = false
    @Published var activeMatchID: String?
    @Published var jumpRange: NSRange?
    @Published var jumpRevision = 0
    private var searchWork: DispatchWorkItem?
    private var lastSearchSignature = ""
    private var diskText = ""
    private var saveWork: DispatchWorkItem?
    private var compileWork: DispatchWorkItem?
    private var poll: Timer?
    private var process: Process?
    private var outputHandle: FileHandle?
    private var compileSignature = ""
    private var observedPDFDate: Date?
    var pdfURL: URL { root.appendingPathComponent("output/pdf/bitirme-raporu.pdf") }
    var fileURL: URL? { selected.map { root.appendingPathComponent("report/" + $0.path) } }
    var groups: [String] { ["Rapor metni", "Belge", "Düzen ve ayarlar", "Korunan şablon", "Görseller"] }

    init() {
        let args = CommandLine.arguments
        let requested = args.firstIndex(of: "--project").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let fallback = Bundle.main.object(forInfoDictionaryKey: "DefaultProjectPath") as? String ?? FileManager.default.currentDirectoryPath
        root = URL(fileURLWithPath: requested ?? UserDefaults.standard.string(forKey: "reportProject") ?? fallback).resolvingSymlinksInPath()
        scan()
        let requestedFile = args.firstIndex(of: "--file").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        if let requestedFile, let file = files.first(where: { $0.path == requestedFile }) { select(file) }
        else if let first = files.first { select(first) }
        refreshPDF()
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkExternalChanges() }
        }
    }

    func scan() {
        let folder = root.appendingPathComponent("report")
        let known: [String: (String, String, String)] = [
            "sections/01-introduction.tex": ("Giriş", "Amaç, kapsam ve literatür", "Rapor metni"),
            "sections/02-analysis.tex": ("Analiz ve fizibilite", "Gereksinimler ve yapılabilirlik", "Rapor metni"),
            "sections/03-design.tex": ("Sistem tasarımı", "Veri, yöntem ve sistem akışı", "Rapor metni"),
            "sections/04-results.tex": ("Deneysel sonuçlar", "Deneyler ve karşılaştırmalar", "Rapor metni"),
            "sections/05-discussion.tex": ("Sonuç ve tartışma", "Katkılar, sınırlar ve gelecek işler", "Rapor metni"),
            "sections/06-appendices.tex": ("Ekler", "Ek belgeler ve bağlantılar", "Rapor metni"),
            "metadata.tex": ("Kapak bilgileri", "Başlık, öğrenci, danışman ve tarih", "Belge"),
            "cover.tex": ("Kapak şablonu", "Sabit biçim · salt okunur", "Korunan şablon"),
            "kaynaklar.bib": ("Kaynakça", "Bilimsel kaynak kayıtları", "Belge"),
            "rapor.tex": ("Bölüm sırası", "Ana dosya · metni bölümlere yaz", "Düzen ve ayarlar"),
            "preamble.tex": ("Biçim şablonu", "Sabit yazı tipi ve sayfa düzeni · salt okunur", "Korunan şablon")
        ]
        var result: [ReportFile] = []
        if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if ["template-original", "build"].contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
                let relative = url.resolvingSymlinksInPath().pathComponents.dropFirst(folder.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
                if relative.hasPrefix("template-original/") || relative.hasPrefix("build/") { enumerator.skipDescendants(); continue }
                guard ["tex", "bib", "png", "jpg", "jpeg", "webp"].contains(url.pathExtension.lowercased()),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let details = known[relative]
                let group = details?.2 ?? (["tex", "bib"].contains(url.pathExtension) ? "Rapor metni" : "Görseller")
                result.append(ReportFile(path: relative, title: details?.0 ?? url.deletingPathExtension().lastPathComponent,
                                         hint: details?.1 ?? relative, group: group))
            }
        }
        files = result.sorted { a,b in
            let ga = groups.firstIndex(of: a.group) ?? 0, gb = groups.firstIndex(of: b.group) ?? 0
            return ga == gb ? a.path < b.path : ga < gb
        }
        if files.isEmpty { error = "Rapor dosyaları bulunamadı. Proje Aç ile rapor proje klasörünü seç." }
    }

    func toggleSidebar() { sidebarVisible.toggle() }

    var searchable: Bool { !ReportSearch.tokens(searchQuery).isEmpty }
    var matchCount: Int { searchResults.reduce(0) { $0 + $1.matches.count } }

    func scheduleSearch() {
        searchWork?.cancel()
        guard searchable else { searchResults = []; searchPending = false; return }
        searchPending = true
        let work = DispatchWorkItem { [weak self] in self?.searchNow() }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func searchNow() {
        searchWork?.cancel()
        guard searchable else { searchResults = []; searchPending = false; return }
        searchResults = files.filter { !$0.isImage }.compactMap { file in
            let content = file == selected ? text : ((try? String(contentsOf: root.appendingPathComponent("report/" + file.path), encoding: .utf8)) ?? "")
            let matches = ReportSearch.matches(query: searchQuery, in: content)
            let titleScore = ReportSearch.score(query: searchQuery, in: file.title + " " + file.path)
            let score = max(titleScore * 1.05, matches.first?.score ?? 0)
            return score > 0 ? FileSearchResult(file: file, matches: matches, score: score) : nil
        }.sorted { $0.score == $1.score ? $0.file.path < $1.file.path : $0.score > $1.score }
        lastSearchSignature = signature()
        searchPending = false
    }

    func openMatch(_ result: FileSearchResult, _ match: TextMatch) {
        select(result.file)
        guard selected == result.file else { return }
        // Results may have become stale after an external edit; refresh before using their ranges.
        let current = ReportSearch.matches(query: searchQuery, in: text)
        guard let updated = current.first(where: { $0.id == match.id }) ?? current.first else { searchNow(); return }
        activeMatchID = result.file.path + ":" + updated.id
        jumpRange = updated.range
        jumpRevision += 1
    }

    func editBibliography(_ entry: BibliographyEntry, original: String, values: [String: String]) -> String? {
        guard selected?.path.hasSuffix(".bib") == true, text == original else {
            return "Kaynakça bu sırada başka yerde değişti. Formu kapatıp kaynağı yeniden aç; değişikliklerini kaybetmemek için önce kopyalayabilirsin."
        }
        guard !conflict else { return "Kaynakça dosyasında iki farklı sürüm var. Önce dosya çakışmasını çöz." }
        edited(Bibliography.replacing(entry, in: original, values: values))
        return nil
    }

    func openPDFSelection(_ selection: String, pageText: String, pageRange: NSRange, isCover: Bool = false) {
        let documents = files.filter { !$0.isImage && (isCover || !$0.isProtected) && $0.path != "rapor.tex" }.compactMap { file -> PDFSourceDocument? in
            let content = file == selected ? text : (try? String(contentsOf: root.appendingPathComponent("report/" + file.path), encoding: .utf8))
            return content.map { PDFSourceDocument(path: file.path, text: $0) }
        }
        guard let location = PDFSourceNavigation.locate(selection: selection, pageText: pageText, pageRange: pageRange, documents: documents, preferredPath: isCover ? "metadata.tex" : nil),
              let file = files.first(where: { $0.path == location.path }) else {
            status = "Kaynakta kesin eşleşme bulunamadı · daha uzun bir metin seç veya PDF’i derle"
            return
        }
        select(file)
        guard selected == file, !conflict else { return }
        sidebarVisible = true
        searchQuery = ""
        activeMatchID = nil
        jumpRange = location.range
        jumpRevision += 1
        let prefix = (text as NSString).substring(to: location.range.location)
        status = "\(file.title) · satır \(prefix.components(separatedBy: .newlines).count)"
    }

    func nextMatch(backward: Bool = false) {
        let all = searchResults.flatMap { result in result.matches.map { (result, $0) } }
        guard !all.isEmpty else { return }
        let index = all.firstIndex { $0.0.file.path + ":" + $0.1.id == activeMatchID }
        let target = index.map { ($0 + (backward ? all.count - 1 : 1)) % all.count } ?? (backward ? all.count - 1 : 0)
        openMatch(all[target].0, all[target].1)
    }

    func select(_ file: ReportFile) {
        guard file != selected else { return }
        guard save() else { return }
        saveWork?.cancel()
        let url = root.appendingPathComponent("report/" + file.path)
        do {
            let content = file.isImage ? "" : try String(contentsOf: url, encoding: .utf8)
            selected = file
            text = content
            diskText = content
            dirty = false
            conflict = false
            error = nil
            status = "Hazır"
            activeMatchID = nil
            jumpRange = nil
        } catch { self.error = "Dosya açılamadı: \(error.localizedDescription)" }
    }

    func edited(_ value: String) {
        guard selected?.isProtected != true else { return }
        text = value
        dirty = text != diskText
        if searchable { scheduleSearch() }
        guard dirty else { return }
        status = "Kaydediliyor…"
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    @discardableResult
    func save() -> Bool {
        saveWork?.cancel()
        guard dirty, let url = fileURL, selected?.isImage == false else { return !conflict }
        guard selected?.isProtected != true else {
            error = "Bu dosya sabit rapor şablonudur; içerik veya kapak bilgileri dosyasını düzenle."
            return false
        }
        do {
            let current = try String(contentsOf: url, encoding: .utf8)
            guard current == diskText || current == text else {
                conflict = true
                error = "Bu dosya başka yerde de değişti. Kendi metnini kopyalayabilir veya diskteki sürümü açabilirsin."
                status = "İki farklı sürüm var"
                return false
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
            diskText = text
            dirty = false
            conflict = false
            status = "Kaydedildi"
            if autoCompile { scheduleCompile() }
            return true
        } catch {
            self.error = "Kaydedilemedi: \(error.localizedDescription)"
            status = "Kaydetme hatası"
            return false
        }
    }

    func useDiskVersion() {
        guard let url = fileURL else { return }
        let alert = NSAlert()
        alert.messageText = "Diskteki sürüm açılsın mı?"
        alert.informativeText = "Düzenleyicideki kaydedilmemiş metin değiştirilecek. Gerekirse önce Kendi Metnimi Kopyala düğmesini kullan."
        alert.addButton(withTitle: "Diskteki Sürümü Aç")
        alert.addButton(withTitle: "Vazgeç")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let value = try String(contentsOf: url, encoding: .utf8)
            text = value; diskText = value; dirty = false; conflict = false; error = nil
            status = "Diskteki sürüm açıldı"
        } catch { self.error = error.localizedDescription }
    }

    func copyDraft() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Metnin panoya kopyalandı"
    }

    func checkExternalChanges() {
        if let url = fileURL, selected?.isImage == false,
           let current = try? String(contentsOf: url, encoding: .utf8), current != diskText {
            if dirty { conflict = true; error = "Dosya başka yerde değişti. Kaydetmeden önce sürümü seç." }
            else { text = current; diskText = current; status = "Dışarıdaki değişiklik yüklendi"; if searchable { scheduleSearch() } }
        }
        if searchable && signature() != lastSearchSignature { scheduleSearch() }
        let date = (try? pdfURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if date != observedPDFDate { refreshPDF() }
    }

    func refreshPDF() {
        observedPDFDate = (try? pdfURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        pdfRevision += 1
    }

    func signature() -> String {
        files.filter { !$0.isImage }.map {
            (try? String(contentsOf: root.appendingPathComponent("report/" + $0.path), encoding: .utf8)) ?? ""
        }.joined(separator: "\u{0}")
    }

    private func scheduleCompile() {
        compileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.compile() }
        compileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func compile() {
        guard !busy else { return }
        compileWork?.cancel()
        // Saving here must not enqueue a duplicate auto-compile.
        let automatic = autoCompile
        autoCompile = false
        let saved = save()
        autoCompile = automatic
        guard saved else { return }
        let script = root.appendingPathComponent("scripts/build_report.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            error = "Derleme komutu bulunamadı. Rapor proje klasörünü aç."; return
        }
        busy = true; status = "PDF derleniyor…"; error = nil; log = ""
        compileSignature = signature()
        let job = Process()
        job.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        job.arguments = ["-u", script.path]
        job.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        job.environment = environment
        // Write to a temporary log, avoiding pipe deadlocks during long first builds.
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("rapor-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            outputHandle = handle
            job.standardOutput = handle; job.standardError = handle
            job.terminationHandler = { [weak self] process in
                let code = process.terminationStatus
                Task { @MainActor in
                    guard let self else { return }
                    try? self.outputHandle?.close(); self.outputHandle = nil
                    self.log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "Derleme günlüğü okunamadı."
                    try? FileManager.default.removeItem(at: logURL)
                    self.busy = false; self.process = nil
                    if code == 0 {
                        self.refreshPDF()
                        self.status = self.signature() == self.compileSignature && !self.dirty ? "PDF güncel" : "PDF hazır · yeni değişiklikler var"
                    } else {
                        self.status = "Derleme tamamlanamadı"
                        self.error = "LaTeX derlenemedi. Ayrıntıları Derleme Günlüğü’nde görebilirsin. Son başarılı PDF korundu."
                        self.showLog = true
                    }
                    if self.autoCompile && (self.dirty || self.signature() != self.compileSignature) { self.scheduleCompile() }
                }
            }
            process = job
            try job.run()
        } catch {
            try? outputHandle?.close(); outputHandle = nil
            try? FileManager.default.removeItem(at: logURL)
            busy = false; process = nil
            self.error = "Derleyici başlatılamadı: \(error.localizedDescription)"
        }
    }

    func chooseProject() {
        guard !busy, save() else { return }
        let panel = NSOpenPanel()
        panel.title = "Rapor proje klasörünü seç"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("report/rapor.tex").path),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/build_report.py").path) else {
            error = "Bu klasörde report/rapor.tex ve scripts/build_report.py bulunamadı."; return
        }
        root = url.resolvingSymlinksInPath()
        UserDefaults.standard.set(root.path, forKey: "reportProject")
        selected = nil; text = ""; diskText = ""; dirty = false; conflict = false
        scan()
        if let first = files.first { select(first) }
        if searchable { scheduleSearch() }
        refreshPDF()
    }

    func exportPDF() {
        guard FileManager.default.fileExists(atPath: pdfURL.path) else { error = "Önce PDF Derle düğmesine bas."; return }
        let panel = NSSavePanel()
        panel.title = "Son derlenen PDF’i kaydet"
        panel.nameFieldStringValue = "Bitirme-Raporu.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        if target.standardizedFileURL == pdfURL.standardizedFileURL { status = "PDF zaten bu konumda"; return }
        do {
            try Data(contentsOf: pdfURL).write(to: target, options: .atomic)
            status = "PDF dışa aktarıldı"
        } catch { self.error = "PDF kaydedilemedi: \(error.localizedDescription)" }
    }
}

struct CodeEditor: NSViewRepresentable {
    @ObservedObject var store: ReportStore
    func makeCoordinator() -> Coordinator { Coordinator(store) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let editor = NSTextView()
        editor.isRichText = false; editor.allowsUndo = true; editor.usesFindBar = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 24, height: 22)
        editor.setAccessibilityIdentifier("reportEditor")
        editor.setAccessibilityLabel("LaTeX metin düzenleyici")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        context.coordinator.editor = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let editor = view.documentView as? NSTextView else { return }
        context.coordinator.store = store
        editor.isEditable = store.selected?.isProtected != true
        if context.coordinator.path != store.selected?.path {
            context.coordinator.path = store.selected?.path
            editor.string = store.text
            editor.undoManager?.removeAllActions()
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.scrollToBeginningOfDocument(nil)
        } else if editor.string != store.text {
            let selection = editor.selectedRange()
            editor.string = store.text
            editor.undoManager?.removeAllActions()
            editor.setSelectedRange(NSRange(location: min(selection.location, (editor.string as NSString).length), length: 0))
        }
        context.coordinator.highlight(fontSize: store.fontSize)
        if context.coordinator.jumpRevision != store.jumpRevision, let range = store.jumpRange,
           NSMaxRange(range) <= (editor.string as NSString).length {
            context.coordinator.jumpRevision = store.jumpRevision
            context.coordinator.reveal(range, in: editor)
        }
    }
    @MainActor class Coordinator: NSObject, NSTextViewDelegate {
        var store: ReportStore
        weak var editor: NSTextView?
        var path: String?
        var styledText = ""
        var styledSize: CGFloat = 0
        var styledSyntax = ""
        var jumpRevision = -1
        init(_ store: ReportStore) { self.store = store }
        func reveal(_ range: NSRange, in editor: NSTextView) {
            editor.setSelectedRange(range)
            editor.scrollRangeToVisible(range)
            editor.showFindIndicator(for: range)
        }
        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            store.edited(editor.string)
            highlight(fontSize: store.fontSize)
        }
        func highlight(fontSize: CGFloat) {
            guard let editor, let storage = editor.textStorage else { return }
            let syntax = store.selected?.path.hasSuffix(".bib") == true ? "bib" : "tex"
            guard styledText != editor.string || styledSize != fontSize || styledSyntax != syntax else { return }
            styledText = editor.string; styledSize = fontSize; styledSyntax = syntax
            let range = NSRange(location: 0, length: storage.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            storage.beginEditing()
            storage.setAttributes([.foregroundColor: NSColor.labelColor,
                                   .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                   .paragraphStyle: paragraph], range: range)
            for (pattern, color) in [(#"\\[a-zA-Z@]+|[{}]"#, NSColor.systemBlue), (#"(?m)(?<!\\)%.*$"#, NSColor.secondaryLabelColor)] {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    for match in regex.matches(in: editor.string, range: range) {
                        storage.addAttribute(.foregroundColor, value: color, range: match.range)
                    }
                }
            }
            if syntax == "bib" { BibliographySyntax.apply(to: storage, fontSize: fontSize) }
            storage.endEditing()
            editor.typingAttributes = [.foregroundColor: NSColor.labelColor,
                                       .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                       .paragraphStyle: paragraph]
        }
    }
}

final class PreviewPDFView: PDFView {
    var revision = -1
    var zoomEvent = 0
    var sourcePath = ""
}
struct PDFPreview: NSViewRepresentable {
    let url: URL
    let revision: Int
    let zoomEvent: Int
    let zoomDirection: Int
    let onSelection: (String, String, NSRange, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelection) }
    func makeNSView(context: Context) -> PreviewPDFView {
        let view = PreviewPDFView()
        view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        view.setAccessibilityLabel("Derlenen rapor PDF önizlemesi")
        view.toolTip = "Bir kelimeyi çift tıkla veya metni seç: kaynak dosyası ilgili konumda açılır."
        context.coordinator.observe(view)
        return view
    }
    func updateNSView(_ view: PreviewPDFView, context: Context) {
        context.coordinator.onSelection = onSelection
        if view.zoomEvent != zoomEvent {
            view.zoomEvent = zoomEvent
            if zoomDirection > 0 { view.zoomIn(nil) }
            else if zoomDirection < 0 { view.zoomOut(nil) }
            else { view.autoScales = true }
        }
        guard view.revision != revision || view.sourcePath != url.path else { return }
        context.coordinator.cancelPendingSelection()
        let sameSource = view.sourcePath == url.path
        let page = sameSource ? view.currentPage.flatMap { view.document?.index(for: $0) } : nil
        view.document = PDFDocument(url: url)
        view.revision = revision; view.sourcePath = url.path
        if let page, let doc = view.document, doc.pageCount > 0, let target = doc.page(at: min(page, doc.pageCount - 1)) { view.go(to: target) }
    }
    static func dismantleNSView(_ view: PreviewPDFView, coordinator: Coordinator) { coordinator.stopObserving() }

    @MainActor final class Coordinator: NSObject {
        var onSelection: (String, String, NSRange, Bool) -> Void
        private weak var view: PreviewPDFView?
        private var pending: DispatchWorkItem?
        init(_ onSelection: @escaping (String, String, NSRange, Bool) -> Void) { self.onSelection = onSelection }
        func observe(_ view: PreviewPDFView) {
            stopObserving()
            self.view = view
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
        }
        func cancelPendingSelection() { pending?.cancel(); pending = nil }
        func stopObserving() {
            cancelPendingSelection()
            NotificationCenter.default.removeObserver(self)
            view = nil
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc private func selectionChanged(_ notification: Notification) {
            cancelPendingSelection()
            guard view?.currentSelection?.string?.isEmpty == false else { return }
            let work = DispatchWorkItem { [weak self] in self?.openSelection() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
        func openSelection() {
            // PDFKit posts during dragging too. Wait for the completed selection, retaining PDF focus for copying.
            guard NSEvent.pressedMouseButtons == 0 else {
                selectionChanged(Notification(name: .PDFViewSelectionChanged))
                return
            }
            guard let selection = view?.currentSelection, let page = selection.pages.first,
                  let pageText = page.string, selection.numberOfTextRanges(on: page) > 0 else { return }
            let range = selection.range(at: 0, on: page)
            guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= (pageText as NSString).length else { return }
            // Use the first contiguous selected range, even for selections spanning pages or columns.
            let text = (pageText as NSString).substring(with: range)
            let isCover = view?.document?.index(for: page) == 0
            onSelection(text, pageText, range, isCover)
        }
    }
}

@MainActor
final class FileRowButton: NSButton {
    var primary = ""
    var secondary = ""
    var symbol = "doc.text"
    var selectedRow = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if selectedRow || isHighlighted {
            (selectedRow ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let foreground = selectedRow ? NSColor.white : NSColor.labelColor
        let secondaryColor = selectedRow ? NSColor.white.withAlphaComponent(0.85) : NSColor.secondaryLabelColor
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
            let tinted = image.copy() as! NSImage
            tinted.lockFocus(); foreground.setFill(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceIn); tinted.unlockFocus()
            tinted.draw(in: NSRect(x: 10, y: 10, width: 17, height: 17), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (primary as NSString).draw(in: NSRect(x: 36, y: 7, width: max(0, bounds.width - 44), height: 19), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: selectedRow ? .semibold : .regular), .foregroundColor: foreground, .paragraphStyle: paragraph])
        (secondary as NSString).draw(in: NSRect(x: 36, y: 28, width: max(0, bounds.width - 44), height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: secondaryColor, .paragraphStyle: paragraph])
    }
}

struct FileRow: NSViewRepresentable {
    let title: String
    let subtitle: String
    let icon: String
    let selected: Bool
    let help: String
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> FileRowButton {
        let button = FileRowButton()
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.target = context.coordinator; button.action = #selector(Coordinator.invoke)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: FileRowButton, context: Context) {
        context.coordinator.action = action
        button.primary = title; button.secondary = subtitle; button.symbol = icon; button.selectedRow = selected
        button.toolTip = help
        button.setAccessibilityLabel(title + ", " + subtitle)
        button.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: ReportStore
    @State private var zoomEvent = 0
    @State private var zoomDirection = 0
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if store.sidebarVisible { sidebar.frame(minWidth: 200, idealWidth: 230, maxWidth: 320) }
                editorPane.frame(minWidth: 320, idealWidth: 540)
                previewPane.frame(minWidth: 320, idealWidth: 530)
            }
            Divider()
            HStack(spacing: 8) {
                if store.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: store.error == nil ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(store.error == nil ? Color.secondary : Color.orange) }
                Text(store.status).font(.system(size: 12))
                Spacer()
                Text("Benim Raporum · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Geliştirme")").font(.system(size: 11)).foregroundStyle(.secondary)
                Button { store.showLog.toggle() } label: { Image(systemName: "terminal") }
                    .buttonStyle(.borderless).help("Derleme günlüğü")
            }.padding(.horizontal, 14).frame(height: 32)
        }
        .frame(minWidth: 960, minHeight: 620)
        .navigationTitle("Benim Raporum")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: store.toggleSidebar) { Label(store.sidebarVisible ? "Dosyaları Gizle" : "Dosyaları Göster", systemImage: "sidebar.left") }
                    .help("Dosyaları göster/gizle · ⌃⌘S")
            }
            ToolbarItem(placement: .navigation) {
                Button(action: store.chooseProject) { Label("Proje Aç", systemImage: "folder") }.disabled(store.busy)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle("Otomatik derle", isOn: $store.autoCompile).toggleStyle(.checkbox).help("Kaydedilen değişikliklerden sonra PDF’i yenile")
                Button(action: { store.compile() }) {
                    HStack(spacing: 6) { Image(systemName: "play.fill"); Text(store.busy ? "Derleniyor…" : "PDF Derle") }
                }.keyboardShortcut("r", modifiers: .command).disabled(store.busy || store.conflict)
                Button(action: store.exportPDF) { HStack(spacing: 6) { Image(systemName: "square.and.arrow.up"); Text("PDF Kaydet…") } }.disabled(store.busy)
            }
        }
        .sheet(isPresented: $store.showLog) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Derleme günlüğü").font(.headline); Spacer(); Button("Kapat") { store.showLog = false }.keyboardShortcut(.cancelAction) }
                ScrollView { Text(store.log.isEmpty ? "Derleme tamamlandığında ayrıntılar burada görünür." : store.log)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(20).frame(width: 740, height: 420)
        }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Benim Raporum").font(.headline)
                Text("Metin yazmak için bir bölüm seç.").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(16)
            HStack(spacing: 4) {
                TextField("Dosya veya içerikte ara", text: $store.searchQuery).textFieldStyle(.roundedBorder)
                    .onSubmit { store.nextMatch() }
                    .help("Dosya adları ve içerik içinde, küçük yazım farklarını da dikkate alarak ara")
                if !store.searchQuery.isEmpty {
                    Button { store.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("Aramayı temizle")
                }
            }.padding(.horizontal, 12).padding(.bottom, 8)
            if store.searchable {
                HStack {
                    Text(store.searchPending ? "Aranıyor…" : "\(store.searchResults.count) dosya · \(store.matchCount) konum")
                    Spacer()
                    Button { store.nextMatch(backward: true) } label: { Image(systemName: "chevron.up") }.help("Önceki sonuç · ⇧⌘G")
                    Button { store.nextMatch() } label: { Image(systemName: "chevron.down") }.help("Sonraki sonuç · ⌘G")
                }.font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.borderless).padding(.horizontal, 12).padding(.bottom, 8)
            }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.searchable {
                        if store.searchResults.isEmpty && !store.searchPending {
                            Text("Sonuç bulunamadı. Daha kısa bir kelime deneyebilirsin.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(store.searchResults) { result in
                            LazyVStack(alignment: .leading, spacing: 3) {
                                FileRow(title: result.file.title, subtitle: result.file.name, icon: "doc.text", selected: store.selected == result.file, help: result.file.hint) { store.select(result.file) }.frame(height: 51)
                                if result.matches.isEmpty {
                                    Text("Dosya adıyla eşleşti").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12)
                                }
                                ForEach(result.matches) { match in
                                    FileRow(title: "Satır \(match.line)", subtitle: match.excerpt, icon: "text.alignleft", selected: store.activeMatchID == result.file.path + ":" + match.id, help: match.excerpt) { store.openMatch(result, match) }.frame(height: 51)
                                }
                            }
                        }
                    } else {
                        ForEach(store.groups, id: \.self) { group in
                            let items = store.files.filter { $0.group == group }
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 5)
                                    ForEach(items) { file in
                                        FileRow(title: file.title, subtitle: file.name, icon: file.isImage ? "photo" : file.group == "Düzen ve ayarlar" ? "slider.horizontal.3" : file.path.hasSuffix(".bib") ? "books.vertical" : "doc.text", selected: store.selected == file, help: file.hint) { store.select(file) }.frame(height: 51).id(file.id)
                                    }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 8)
            }
            .onChange(of: store.selected?.id) { _, path in
                if let path { proxy.scrollTo(path, anchor: .center) }
            }
            .onAppear { if let path = store.selected?.id { proxy.scrollTo(path, anchor: .center) } }
            }
            Spacer(minLength: 0)
            Divider()
            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.root.appendingPathComponent("report").path) } label: { Label("Finder’da Göster", systemImage: "folder") }
                .buttonStyle(.borderless).padding(14)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    var editorPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.selected?.title ?? "Bir dosya seç").font(.headline)
                    Text(store.selected?.hint ?? "Soldaki listeden bir bölüm aç.").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button { store.fontSize = max(11, store.fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }.help("Yazıyı küçült")
                Button { store.fontSize = min(24, store.fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }.help("Yazıyı büyüt")
            }.buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 66)
            Divider()
            if store.selected?.group == "Rapor metni" {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.line")
                    Text("Metni buraya yaz. Mavi ifadeler LaTeX komutlarıdır.")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 9)
                Divider()
            }
            if store.selected?.isProtected == true {
                Label("Korunan şablon · salt okunur. Metni bölüm dosyalarında geliştir.", systemImage: "lock")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
            }
            if let error = store.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    if store.conflict {
                        HStack {
                            Button("Kendi Metnimi Kopyala", action: store.copyDraft)
                            Button("Diskteki Sürümü Aç", action: store.useDiskVersion)
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1))
            }
            if store.selected?.isImage == true, let url = store.fileURL, let image = NSImage(contentsOf: url) {
                Spacer(); Image(nsImage: image).resizable().scaledToFit().padding(30); Spacer()
            } else if store.selected?.path.hasSuffix(".bib") == true {
                BibliographyEditor(store: store).id(store.selected?.path)
            } else if store.selected != nil {
                CodeEditor(store: store)
            } else { Spacer() }
            Divider()
            HStack {
                Text(store.selected?.path ?? "").lineLimit(1).truncationMode(.middle)
                Spacer()
                if store.selected?.isImage != true { Text("\(store.text.components(separatedBy: .newlines).count) satır · UTF-8") }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 26)
        }.background(Color(nsColor: .textBackgroundColor))
    }
    var previewPane: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PDF önizlemesi").font(.headline)
                    Text("Metin seç → kaynakta aç").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { zoomDirection = -1; zoomEvent += 1 } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.borderless).help("PDF’i küçült")
                Button { zoomDirection = 0; zoomEvent += 1 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.borderless).help("Sayfayı pencereye sığdır")
                Button { zoomDirection = 1; zoomEvent += 1 } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.borderless).help("PDF’i büyüt")
                Button { NSWorkspace.shared.open(store.pdfURL) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless).help("Önizleme’de aç")
            }.padding(.horizontal, 18).frame(height: 66)
            Divider()
            if FileManager.default.fileExists(atPath: store.pdfURL.path) {
                PDFPreview(url: store.pdfURL, revision: store.pdfRevision, zoomEvent: zoomEvent, zoomDirection: zoomDirection, onSelection: store.openPDFSelection)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.richtext").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Raporunu burada göreceksin").font(.headline)
                    Text("Metni düzenle, sonra PDF Derle’ye bas.").font(.callout).foregroundStyle(.secondary)
                    Button("PDF Derle", action: store.compile).disabled(store.busy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: ReportStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if store.busy {
            let alert = NSAlert()
            alert.messageText = "PDF derlemesi sürüyor"
            alert.informativeText = "Derleme tamamlandığında uygulamayı kapatabilirsin."
            alert.addButton(withTitle: "Tamam"); alert.runModal()
            return .terminateCancel
        }
        return store.save() ? .terminateNow : .terminateCancel
    }
}

#if !RAPOR_TEST
@main
struct RaporApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = ReportStore()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).onAppear { delegate.store = store }
        }
        .defaultSize(width: 1360, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Proje Aç…", action: store.chooseProject).keyboardShortcut("o").disabled(store.busy) }
            CommandGroup(replacing: .saveItem) {
                Button("Kaydet") { _ = store.save() }.keyboardShortcut("s")
                Button("PDF Kaydet…", action: store.exportPDF).keyboardShortcut("e", modifiers: [.command, .shift]).disabled(store.busy)
            }
            CommandGroup(after: .toolbar) {
                Button(store.sidebarVisible ? "Dosyaları Gizle" : "Dosyaları Göster", action: store.toggleSidebar).keyboardShortcut("s", modifiers: [.command, .control])
                Button("Sonraki Arama Sonucu") { store.nextMatch() }.keyboardShortcut("g").disabled(store.matchCount == 0)
                Button("Önceki Arama Sonucu") { store.nextMatch(backward: true) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(store.matchCount == 0)
                Button("Derleme Günlüğü") { store.showLog.toggle() }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

#endif
