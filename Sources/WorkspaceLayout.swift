import Foundation

struct WorkspaceGroup: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var localizeName = false
}

struct WorkspaceFileSettings: Codable, Equatable {
    var groupID: String?
    var title: String?
}

struct WorkspaceLayout: Codable, Equatable {
    var version = 1
    var groups: [WorkspaceGroup] = []
    var files: [String: WorkspaceFileSettings] = [:]

    static let ungrouped = WorkspaceGroup(id: "auto:ungrouped", name: "Ungrouped", localizeName: true)

    static func defaultGroup(for path: String) -> WorkspaceGroup {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if ["cover.tex", "preamble.tex"].contains(path) {
            return WorkspaceGroup(id: "auto:template", name: "Protected template", localizeName: true)
        }
        if ["png", "jpg", "jpeg", "webp"].contains(ext) {
            return WorkspaceGroup(id: "auto:images", name: "Images", localizeName: true)
        }
        if ext == "bib" {
            return WorkspaceGroup(id: "auto:references", name: "References", localizeName: true)
        }
        let folder = (path as NSString).deletingLastPathComponent
        if !folder.isEmpty {
            return WorkspaceGroup(id: "folder:" + folder, name: folder == "sections" ? "Report text" : readableName(folder), localizeName: folder == "sections")
        }
        return WorkspaceGroup(id: "auto:document", name: "Document", localizeName: true)
    }

    static func automatic(paths: [String]) -> WorkspaceLayout {
        var result = WorkspaceLayout()
        for path in paths.sorted() {
            let group = defaultGroup(for: path)
            if !result.groups.contains(where: { $0.id == group.id }) { result.groups.append(group) }
            result.files[path] = WorkspaceFileSettings(groupID: group.id)
        }
        // Folder text first, then document, references, templates and images. Folder names remain dynamic.
        func rank(_ id: String) -> Int {
            if id.hasPrefix("folder:") { return 0 }
            return ["auto:document", "auto:references", "auto:template", "auto:images"].firstIndex(of: id).map { $0 + 1 } ?? 6
        }
        result.groups.sort { rank($0.id) == rank($1.id) ? $0.id < $1.id : rank($0.id) < rank($1.id) }
        return result
    }

    /// Keep custom names/order and place new or unassigned files in a known group.
    func including(paths: [String]) -> WorkspaceLayout {
        var result = self
        for path in paths {
            if result.files[path] == nil {
                let candidate = Self.defaultGroup(for: path)
                let groupID = result.groups.contains(where: { $0.id == candidate.id }) ? candidate.id : Self.ungrouped.id
                result.files[path] = WorkspaceFileSettings(groupID: groupID)
            }
            if !result.groups.contains(where: { $0.id == result.files[path]?.groupID }) {
                result.files[path]?.groupID = Self.ungrouped.id
            }
            if result.files[path]?.groupID == Self.ungrouped.id && !result.groups.contains(where: { $0.id == Self.ungrouped.id }) {
                result.groups.append(Self.ungrouped)
            }
        }
        return result
    }

    mutating func removeGroup(_ id: String, paths: [String]) {
        groups.removeAll { $0.id == id }
        for path in Array(files.keys) where files[path]?.groupID == id { files[path]?.groupID = nil }
        self = including(paths: paths)
    }

    func isValid() -> Bool {
        guard version == 1, Set(groups.map(\.id)).count == groups.count else { return false }
        let names = groups.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !groups.contains(where: { $0.id.isEmpty }), !names.contains(""), Set(names).count == names.count else { return false }
        return files.keys.allSatisfy { !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }
    }

    static func readableName(_ path: String) -> String {
        let name = (path as NSString).deletingPathExtension
            .replacingOccurrences(of: #"(^|/)[0-9]+[-_. ]*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " / ").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? path : name.prefix(1).uppercased() + name.dropFirst()
    }

    static func sourceTitle(_ source: String, path: String) -> String {
        let fallback = readableName((path as NSString).lastPathComponent)
        // Only top-level lines: commented examples and inline commands are not section headings.
        let regex = try! NSRegularExpression(pattern: #"(?m)^[ \t]*\\(?:chapter|section)\*?(?:\[[^\]\n]*\])?[ \t\r\n]*\{"#)
        let text = source as NSString
        guard let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: text.length)) else { return fallback }
        let units = Array(source.utf16)
        let start = NSMaxRange(match.range)
        var i = start, depth = 1
        while i < units.count {
            if units[i] == 92 { i += 2; continue }
            if units[i] == 123 { depth += 1 }
            if units[i] == 125 { depth -= 1; if depth == 0 { break } }
            i += 1
        }
        guard depth == 0 else { return fallback }
        let title = Bibliography.display(text.substring(with: NSRange(location: start, length: i - start)))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return title.isEmpty || title.contains("\\") ? fallback : title
    }
}
