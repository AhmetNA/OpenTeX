import Foundation

enum ReportFileTypes {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic", "svg"]
    static let tableExtensions: Set<String> = ["csv", "tsv", "xlsx", "xls", "ods"]
    static let textExtensions: Set<String> = ["tex", "bib", "csv", "tsv", "txt"]
    static let supportedExtensions = imageExtensions.union(tableExtensions).union(textExtensions).union(["pdf"])
    static func folder(for ext: String) -> String {
        if imageExtensions.contains(ext) || ext == "pdf" { return "assets" }
        if tableExtensions.contains(ext) { return "tables" }
        if ext == "tex" { return "sections" }
        if ext == "bib" { return "references" }
        return "attachments"
    }
}

struct ReportFileImport {
    struct Imported {
        let path: String
        let copied: Bool
    }
    struct Issue {
        let filename: String
        let message: String
    }
    struct Result {
        var files: [Imported] = []
        var issues: [Issue] = []
    }

    private static func contains(_ child: URL, in parent: URL) -> Bool {
        let parentParts = parent.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let childParts = child.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return childParts.count > parentParts.count && childParts.starts(with: parentParts)
    }

    /// Copy user-selected files. Never move originals, overwrite a destination, or modify a template.
    static func copy(_ urls: [URL], into project: URL) -> Result {
        let manager = FileManager.default
        let project = project.resolvingSymlinksInPath()
        let report = project.appendingPathComponent("report", isDirectory: true).resolvingSymlinksInPath()
        var result = Result()
        let validReport = contains(report, in: project) && (try? report.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        var seen = Set<String>()
        for url in urls {
            guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
            let filename = url.lastPathComponent
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard validReport else { result.issues.append(Issue(filename: filename, message: "The project report folder is unavailable.")); continue }
            guard !filename.hasPrefix("."), url.isFileURL, ReportFileTypes.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                result.issues.append(Issue(filename: filename, message: "This file type is not supported.")); continue
            }
            let source = url.resolvingSymlinksInPath()
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                result.issues.append(Issue(filename: filename, message: "Drop individual files, not folders.")); continue
            }
            if contains(source, in: report) {
                let relative = source.pathComponents.dropFirst(report.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
                if !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") || ["build", "template-original"].contains(String($0)) }) {
                    result.files.append(Imported(path: relative, copied: false)); continue
                }
            }
            let folder = report.appendingPathComponent(ReportFileTypes.folder(for: url.pathExtension.lowercased()), isDirectory: true)
            guard contains(folder, in: report), (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                result.issues.append(Issue(filename: filename, message: "The destination folder points outside this project.")); continue
            }
            let staging = folder.appendingPathComponent(".opentex-import-" + UUID().uuidString)
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                // Stage in the destination directory: a failed copy never leaves a partial visible file.
                try manager.copyItem(at: source, to: staging)
                defer { try? manager.removeItem(at: staging) }
                let stem = (filename as NSString).deletingPathExtension
                let ext = (filename as NSString).pathExtension
                var number = 1
                while true {
                    let name = number == 1 ? filename : "\(stem) (\(number)).\(ext)"
                    let target = folder.appendingPathComponent(name)
                    if manager.fileExists(atPath: target.path) { number += 1; continue }
                    do {
                        try manager.moveItem(at: staging, to: target)
                        let relative = target.pathComponents.dropFirst(report.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
                        result.files.append(Imported(path: relative, copied: true))
                        break
                    } catch {
                        // Another importer may have taken this name after the existence check.
                        if manager.fileExists(atPath: target.path) { number += 1; continue }
                        throw error
                    }
                }
            } catch {
                try? manager.removeItem(at: staging)
                result.issues.append(Issue(filename: filename, message: error.localizedDescription))
            }
        }
        return result
    }
}
