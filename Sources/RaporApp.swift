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
    @Published var workspace = WorkspaceLayout()
    @Published var showOrganizer = false
    private(set) var workspaceSnapshot: Data?
    private var workspaceReadable = true
    var workspaceURL: URL { root.appendingPathComponent(".opentex/workspace.json") }
    @Published var selected: ReportFile?
    @Published var text = ""
    @Published var dirty = false
    @Published var conflict = false
    @Published var busy = false
    @Published var status = L("Ready")
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
    var groups: [WorkspaceGroup] { workspace.groups }

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
        let previous = files
        workspaceSnapshot = try? Data(contentsOf: workspaceURL)
        var saved: WorkspaceLayout?
        workspaceReadable = true
        if let data = workspaceSnapshot {
            if let decoded = try? JSONDecoder().decode(WorkspaceLayout.self, from: data), decoded.isValid() { saved = decoded }
            else { workspaceReadable = false; error = L("The saved file layout could not be read. Your configuration was kept unchanged.") }
        } else if FileManager.default.fileExists(atPath: workspaceURL.path) {
            workspaceReadable = false
            error = L("The saved file layout could not be read. Your configuration was kept unchanged.")
        }
        let special: [String: (String, String)] = [
            "metadata.tex": (L("Cover details"), L("Title, student, supervisor and date")),
            "rapor.tex": (L("Section order"), L("Main file · write content in section files")),
            "cover.tex": (L("Cover template"), L("Fixed format · read-only")),
            "preamble.tex": (L("Layout template"), L("Fixed typography and page layout · read-only"))
        ]
        var result: [ReportFile] = []
        if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if ["template-original", "build"].contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
                let relative = url.resolvingSymlinksInPath().pathComponents.dropFirst(folder.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
                if relative.hasPrefix("template-original/") || relative.hasPrefix("build/") { enumerator.skipDescendants(); continue }
                guard ["tex", "bib", "png", "jpg", "jpeg", "webp"].contains(url.pathExtension.lowercased()),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let content = url.pathExtension.lowercased() == "tex" ? (relative == selected?.path ? text : ((try? String(contentsOf: url, encoding: .utf8)) ?? "")) : ""
                let automatic = special[relative]?.0 ?? (url.pathExtension.lowercased() == "tex" ? WorkspaceLayout.sourceTitle(content, path: relative) : WorkspaceLayout.readableName(url.deletingPathExtension().lastPathComponent))
                let custom = saved?.files[relative]?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(ReportFile(path: relative, title: custom?.isEmpty == false ? custom! : automatic,
                                         hint: special[relative]?.1 ?? relative, group: ""))
            }
        }
        let paths = result.map(\.path)
        let updatedWorkspace = saved?.including(paths: paths) ?? .automatic(paths: paths)
        if workspace != updatedWorkspace { workspace = updatedWorkspace }
        let updatedFiles = result.map { file in
            ReportFile(path: file.path, title: file.title, hint: file.hint, group: workspace.files[file.path]?.groupID ?? WorkspaceLayout.ungrouped.id)
        }.sorted { a,b in
            let ga = groups.firstIndex(where: { $0.id == a.group }) ?? 0, gb = groups.firstIndex(where: { $0.id == b.group }) ?? 0
            return ga == gb ? a.path < b.path : ga < gb
        }
        if files != updatedFiles { files = updatedFiles }
        // Metadata changes must never reload or save the current draft, reset undo, or lose its source selection.
        if let path = selected?.path, let updated = files.first(where: { $0.path == path }), updated != selected { selected = updated }
        if searchable && previous != files { scheduleSearch() }
        if files.isEmpty { error = L("Report files were not found. Use Open Project to select the report project folder.") }
    }

    func saveWorkspace(_ layout: WorkspaceLayout, original: Data?, expectedRoot: URL) -> String? {
        guard root == expectedRoot else { return L("The project changed. Reopen Organize Files and try again.") }
        guard workspaceReadable else { return L("The saved file layout could not be read. Your configuration was kept unchanged.") }
        let names = layout.groups.map { ($0.localizeName ? L($0.name) : $0.name).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard layout.isValid(), Set(names).count == names.count else { return L("Give every group a unique, nonempty name.") }
        do {
            let current = FileManager.default.fileExists(atPath: workspaceURL.path) ? try Data(contentsOf: workspaceURL) : nil
            guard current == original else { return L("The file layout changed elsewhere. Reopen Organize Files to load the latest version.") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(layout.including(paths: files.map(\.path)))
            try FileManager.default.createDirectory(at: workspaceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: workspaceURL, options: .atomic)
            scan()
            status = L("File layout saved")
            return nil
        } catch { return L("Could not save file layout: %@", error.localizedDescription) }
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
            return L("The bibliography changed elsewhere while this form was open. Copy your changes if needed, then close the form and reopen the reference.")
        }
        guard !conflict else { return L("The bibliography has conflicting versions. Resolve the file conflict first.") }
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
            status = L("No exact source match · select a longer passage or compile the PDF")
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
        status = L("%@ · line %d", file.title, prefix.components(separatedBy: .newlines).count)
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
            status = L("Ready")
            activeMatchID = nil
            jumpRange = nil
        } catch { self.error = L("Could not open file: %@", error.localizedDescription) }
    }

    func edited(_ value: String) {
        guard selected?.isProtected != true else { return }
        text = value
        dirty = text != diskText
        if searchable { scheduleSearch() }
        guard dirty else { return }
        status = L("Saving…")
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
            error = L("This is a protected report template. Edit a section or the cover details file instead.")
            return false
        }
        do {
            let current = try String(contentsOf: url, encoding: .utf8)
            guard current == diskText || current == text else {
                conflict = true
                error = L("This file also changed elsewhere. You can copy your draft or open the version on disk.")
                status = L("Conflicting versions")
                return false
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
            diskText = text
            dirty = false
            conflict = false
            status = L("Saved")
            if autoCompile { scheduleCompile() }
            return true
        } catch {
            self.error = L("Could not save: %@", error.localizedDescription)
            status = L("Save error")
            return false
        }
    }

    func useDiskVersion() {
        guard let url = fileURL else { return }
        let alert = NSAlert()
        alert.messageText = L("Open the version on disk?")
        alert.informativeText = L("Unsaved text in the editor will be replaced. Use Copy My Draft first if you need to keep it.")
        alert.addButton(withTitle: L("Open Disk Version"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let value = try String(contentsOf: url, encoding: .utf8)
            text = value; diskText = value; dirty = false; conflict = false; error = nil
            status = L("Opened disk version")
        } catch { self.error = error.localizedDescription }
    }

    func copyDraft() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = L("Draft copied to clipboard")
    }

    func checkExternalChanges() {
        scan()
        if let url = fileURL, selected?.isImage == false,
           let current = try? String(contentsOf: url, encoding: .utf8), current != diskText {
            if dirty { conflict = true; error = L("The file changed elsewhere. Choose a version before saving.") }
            else { text = current; diskText = current; status = L("External changes loaded"); if searchable { scheduleSearch() } }
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
            error = L("Build script not found. Open the report project folder."); return
        }
        busy = true; status = L("Compiling PDF…"); error = nil; log = ""
        compileSignature = signature()
        let job = Process()
        job.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        job.arguments = ["-u", script.path]
        job.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        job.environment = environment
        // Write to a temporary log, avoiding pipe deadlocks during long first builds.
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("opentex-\(UUID().uuidString).log")
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
                    self.log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? L("The build log could not be read.")
                    try? FileManager.default.removeItem(at: logURL)
                    self.busy = false; self.process = nil
                    if code == 0 {
                        self.refreshPDF()
                        self.status = self.signature() == self.compileSignature && !self.dirty ? L("PDF is up to date") : L("PDF ready · new changes pending")
                    } else {
                        self.status = L("Build failed")
                        self.error = L("LaTeX compilation failed. See the Build Log for details. The last successful PDF was kept.")
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
            self.error = L("Could not start compiler: %@", error.localizedDescription)
        }
    }

    func chooseProject() {
        guard !busy, save() else { return }
        let panel = NSOpenPanel()
        panel.title = L("Select a report project folder")
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("report/rapor.tex").path),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/build_report.py").path) else {
            error = L("This folder does not contain report/rapor.tex and scripts/build_report.py."); return
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
        guard FileManager.default.fileExists(atPath: pdfURL.path) else { error = L("Click Compile PDF first."); return }
        let panel = NSSavePanel()
        panel.title = L("Save the last compiled PDF")
        panel.nameFieldStringValue = L("Report.pdf")
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        if target.standardizedFileURL == pdfURL.standardizedFileURL { status = L("The PDF is already at this location"); return }
        do {
            try Data(contentsOf: pdfURL).write(to: target, options: .atomic)
            status = L("PDF exported")
        } catch { self.error = L("Could not save PDF: %@", error.localizedDescription) }
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
        editor.setAccessibilityLabel(L("LaTeX source editor"))
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
        view.setAccessibilityLabel(L("Compiled report PDF preview"))
        view.toolTip = L("Double-click a word or select text to open its location in the source file.")
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
                Text(L("OpenTeX · %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("Development"))).font(.system(size: 11)).foregroundStyle(.secondary)
                Button { store.showLog.toggle() } label: { Image(systemName: "terminal") }
                    .buttonStyle(.borderless).help(L("Build log"))
            }.padding(.horizontal, 14).frame(height: 32)
        }
        .frame(minWidth: 960, minHeight: 620)
        .navigationTitle("OpenTeX")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: store.toggleSidebar) { Label(store.sidebarVisible ? L("Hide Files") : L("Show Files"), systemImage: "sidebar.left") }
                    .help(L("Show/hide files · ⌃⌘S"))
            }
            ToolbarItem(placement: .navigation) {
                Button(action: store.chooseProject) { Label(L("Open Project"), systemImage: "folder") }.disabled(store.busy)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(L("Auto compile"), isOn: $store.autoCompile).toggleStyle(.checkbox).help(L("Refresh the PDF after saving changes"))
                Button(action: { store.compile() }) {
                    HStack(spacing: 6) { Image(systemName: "play.fill"); Text(store.busy ? L("Compiling…") : L("Compile PDF")) }
                }.keyboardShortcut("r", modifiers: .command).disabled(store.busy || store.conflict)
                Button(action: store.exportPDF) { HStack(spacing: 6) { Image(systemName: "square.and.arrow.up"); Text(L("Export PDF…")) } }.disabled(store.busy)
            }
        }
        .sheet(isPresented: $store.showOrganizer) { WorkspaceOrganizer(store: store) }
        .sheet(isPresented: $store.showLog) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(L("Build log")).font(.headline); Spacer(); Button(L("Close")) { store.showLog = false }.keyboardShortcut(.cancelAction) }
                ScrollView { Text(store.log.isEmpty ? L("Build details will appear here when compilation finishes.") : store.log)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(20).frame(width: 740, height: 420)
        }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("OpenTeX").font(.headline)
                    Spacer()
                    Button { store.showOrganizer = true } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless).help(L("Organize Files"))
                }
                Text(L("Select a section to start writing.")).font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(16)
            HStack(spacing: 4) {
                TextField(L("Search files or content"), text: $store.searchQuery).textFieldStyle(.roundedBorder)
                    .onSubmit { store.nextMatch() }
                    .help(L("Search filenames and content, allowing small typing differences"))
                if !store.searchQuery.isEmpty {
                    Button { store.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help(L("Clear search"))
                }
            }.padding(.horizontal, 12).padding(.bottom, 8)
            if store.searchable {
                HStack {
                    Text(store.searchPending ? L("Searching…") : L("Files: %d · Matches: %d", store.searchResults.count, store.matchCount))
                    Spacer()
                    Button { store.nextMatch(backward: true) } label: { Image(systemName: "chevron.up") }.help(L("Previous result · ⇧⌘G"))
                    Button { store.nextMatch() } label: { Image(systemName: "chevron.down") }.help(L("Next result · ⌘G"))
                }.font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.borderless).padding(.horizontal, 12).padding(.bottom, 8)
            }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.searchable {
                        if store.searchResults.isEmpty && !store.searchPending {
                            Text(L("No results. Try a shorter word."))
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(store.searchResults) { result in
                            LazyVStack(alignment: .leading, spacing: 3) {
                                FileRow(title: result.file.title, subtitle: result.file.name, icon: "doc.text", selected: store.selected == result.file, help: result.file.hint) { store.select(result.file) }.frame(height: 51)
                                if result.matches.isEmpty {
                                    Text(L("Matched filename")).font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12)
                                }
                                ForEach(result.matches) { match in
                                    FileRow(title: L("Line %d", match.line), subtitle: match.excerpt, icon: "text.alignleft", selected: store.activeMatchID == result.file.path + ":" + match.id, help: match.excerpt) { store.openMatch(result, match) }.frame(height: 51)
                                }
                            }
                        }
                    } else {
                        ForEach(store.groups) { group in
                            let items = store.files.filter { $0.group == group.id }
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.localizeName ? L(group.name) : group.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 5)
                                    ForEach(items) { file in
                                        FileRow(title: file.title, subtitle: file.name, icon: file.isImage ? "photo" : file.path == "rapor.tex" ? "slider.horizontal.3" : file.path.hasSuffix(".bib") ? "books.vertical" : "doc.text", selected: store.selected == file, help: file.hint) { store.select(file) }.frame(height: 51).id(file.id)
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
            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.root.appendingPathComponent("report").path) } label: { Label(L("Show in Finder"), systemImage: "folder") }
                .buttonStyle(.borderless).padding(14)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    var editorPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.selected?.title ?? L("Select a file")).font(.headline)
                    Text(store.selected?.hint ?? L("Open a section from the list on the left.")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button { store.fontSize = max(11, store.fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }.help(L("Decrease text size"))
                Button { store.fontSize = min(24, store.fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }.help(L("Increase text size"))
            }.buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 66)
            Divider()
            if store.selected?.path.hasSuffix(".tex") == true && store.selected?.isProtected == false {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.line")
                    Text(L("Write your text here. Blue expressions are LaTeX commands."))
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 9)
                Divider()
            }
            if store.selected?.isProtected == true {
                Label(L("Protected template · read-only. Write your content in section files."), systemImage: "lock")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
            }
            if let error = store.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    if store.conflict {
                        HStack {
                            Button(L("Copy My Draft"), action: store.copyDraft)
                            Button(L("Open Disk Version"), action: store.useDiskVersion)
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
                if store.selected?.isImage != true { Text(L("Lines: %d · UTF-8", store.text.components(separatedBy: .newlines).count)) }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 26)
        }.background(Color(nsColor: .textBackgroundColor))
    }
    var previewPane: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("PDF preview")).font(.headline)
                    Text(L("Select text → reveal source")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { zoomDirection = -1; zoomEvent += 1 } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.borderless).help(L("Zoom out PDF"))
                Button { zoomDirection = 0; zoomEvent += 1 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.borderless).help(L("Fit page to window"))
                Button { zoomDirection = 1; zoomEvent += 1 } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.borderless).help(L("Zoom in PDF"))
                Button { NSWorkspace.shared.open(store.pdfURL) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless).help(L("Open in Preview"))
            }.padding(.horizontal, 18).frame(height: 66)
            Divider()
            if FileManager.default.fileExists(atPath: store.pdfURL.path) {
                PDFPreview(url: store.pdfURL, revision: store.pdfRevision, zoomEvent: zoomEvent, zoomDirection: zoomDirection, onSelection: store.openPDFSelection)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.richtext").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(L("Your report will appear here")).font(.headline)
                    Text(L("Edit the text, then click Compile PDF.")).font(.callout).foregroundStyle(.secondary)
                    Button(L("Compile PDF"), action: store.compile).disabled(store.busy)
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
            alert.messageText = L("PDF compilation is in progress")
            alert.informativeText = L("You can quit the app when compilation finishes.")
            alert.addButton(withTitle: L("OK")); alert.runModal()
            return .terminateCancel
        }
        return store.save() ? .terminateNow : .terminateCancel
    }
}

#if !RAPOR_TEST
@main
struct OpenTeXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = ReportStore()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).onAppear { delegate.store = store }
        }
        .defaultSize(width: 1360, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) { Button(L("Open Project…"), action: store.chooseProject).keyboardShortcut("o").disabled(store.busy) }
            CommandGroup(replacing: .saveItem) {
                Button(L("Save")) { _ = store.save() }.keyboardShortcut("s")
                Button(L("Export PDF…"), action: store.exportPDF).keyboardShortcut("e", modifiers: [.command, .shift]).disabled(store.busy)
            }
            CommandGroup(after: .toolbar) {
                Button(store.sidebarVisible ? L("Hide Files") : L("Show Files"), action: store.toggleSidebar).keyboardShortcut("s", modifiers: [.command, .control])
                Button(L("Organize Files…")) { store.showOrganizer = true }
                Button(L("Next Search Result")) { store.nextMatch() }.keyboardShortcut("g").disabled(store.matchCount == 0)
                Button(L("Previous Search Result")) { store.nextMatch(backward: true) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(store.matchCount == 0)
                Button(L("Build Log")) { store.showLog.toggle() }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

#endif
