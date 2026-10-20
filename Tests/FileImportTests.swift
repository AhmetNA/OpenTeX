import Foundation

@main struct FileImportChecks {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("opentex-import-test-" + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let originals = root.appendingPathComponent("originals")
        try manager.createDirectory(at: project.appendingPathComponent("report/assets"), withIntermediateDirectories: true)
        try manager.createDirectory(at: originals, withIntermediateDirectories: true)
        let png = originals.appendingPathComponent("photo.png")
        let csv = originals.appendingPathComponent("Türkçe tablo.csv")
        let excel = originals.appendingPathComponent("data.xlsx")
        let pdf = originals.appendingPathComponent("plot.pdf")
        let tex = originals.appendingPathComponent("preamble.tex")
        for (url, value) in [(png,"image bytes"),(csv,"year,score\n2026,1"),(excel,"binary spreadsheet"),(pdf,"pdf bytes"),(tex,"new user source")] {
            try Data(value.utf8).write(to: url)
        }
        let protectedSource = project.appendingPathComponent("report/preamble.tex")
        let logo = project.appendingPathComponent("report/assets/photo.png")
        try Data("protected source".utf8).write(to: protectedSource)
        try Data("existing image".utf8).write(to: logo)
        let result = ReportFileImport.copy([png, csv, excel, pdf, tex, png], into: project)
        assert(result.issues.isEmpty && result.files.count == 5)
        assert(result.files.contains { $0.path == "assets/photo (2).png" && $0.copied })
        assert(result.files.contains { $0.path == "tables/Türkçe tablo.csv" })
        assert(result.files.contains { $0.path == "tables/data.xlsx" })
        assert(result.files.contains { $0.path == "assets/plot.pdf" })
        assert(result.files.contains { $0.path == "sections/preamble.tex" })
        assert(tryBytes(protectedSource) == Data("protected source".utf8))
        assert(tryBytes(logo) == Data("existing image".utf8))
        assert(tryBytes(png) == Data("image bytes".utf8))
        assert(tryBytes(project.appendingPathComponent("report/tables/Türkçe tablo.csv")) == tryBytes(csv))
        let existing = ReportFileImport.copy([logo], into: project)
        assert(existing.files.count == 1 && !existing.files[0].copied)
        let unsupported = originals.appendingPathComponent("program.sh")
        try Data("ignored".utf8).write(to: unsupported)
        let partial = ReportFileImport.copy([unsupported, originals, URL(string: "https://example.org/image.png")!, png], into: project)
        assert(partial.issues.count == 3 && partial.files.count == 1)
        assert(partial.files[0].path == "assets/photo (3).png")
        let outside = root.appendingPathComponent("outside")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try manager.removeItem(at: project.appendingPathComponent("report/tables"))
        try manager.createSymbolicLink(at: project.appendingPathComponent("report/tables"), withDestinationURL: outside)
        assert(ReportFileImport.copy([csv], into: project).files.isEmpty)
        let outsideContents = try manager.contentsOfDirectory(atPath: outside.path)
        assert(outsideContents.isEmpty)
        let missing = ReportFileImport.copy([png], into: root.appendingPathComponent("missing"))
        assert(missing.files.isEmpty && missing.issues.count == 1)
        let leftovers = try manager.contentsOfDirectory(atPath: project.appendingPathComponent("report/assets").path)
        assert(!leftovers.contains { $0.hasPrefix(".opentex-import-") })
        print("PASS: multi-file imports, Unicode names, byte-preserving copies, collision renaming, original/template preservation, existing files, partial failure and symlink destination protection.")
    }
    static func tryBytes(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }
}
