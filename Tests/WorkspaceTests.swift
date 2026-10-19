import Foundation

@main struct WorkspaceTests {
    static func main() throws {
        let paths = ["chapters/03-evaluation.tex", "sections/01-intro.tex", "references.bib", "cover.tex", "assets/logo.png", "metadata.tex"]
        let automatic = WorkspaceLayout.automatic(paths: paths)
        assert(automatic.isValid())
        assert(automatic.files.count == paths.count && automatic.groups.count == 6)
        assert(automatic.groups.contains { $0.name == "Chapters" })
        assert(WorkspaceLayout.sourceTitle("% \\section{Not a title}\n\\chapter*{Methods and \\emph{Results}}", path: paths[0]) == "Methods and Results")
        assert(WorkspaceLayout.sourceTitle("\\section[Short]{Research \\& Design}", path: "part.tex") == "Research & Design")
        assert(WorkspaceLayout.sourceTitle("\\section{Missing brace", path: "07-evaluation_results.tex") == "Evaluation results")
        assert(WorkspaceLayout.sourceTitle("\\newcommand{\\example}{\\section{Not a title}}", path: "test.tex") == "Test")
        var custom = automatic
        custom.groups.insert(WorkspaceGroup(id: "mine", name: "Literature notes"), at: 0)
        custom.files[paths[0]] = WorkspaceFileSettings(groupID: "mine", title: "Evaluation")
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        assert(decoded == custom)
        var expanded = decoded.including(paths: paths + ["chapters/04-limits.tex", "appendices/extra.tex"])
        assert(expanded.groups.first?.id == "mine")
        assert(expanded.files[paths[0]]?.title == "Evaluation")
        assert(expanded.files["chapters/04-limits.tex"]?.groupID == "folder:chapters")
        assert(expanded.files["appendices/extra.tex"]?.groupID == WorkspaceLayout.ungrouped.id)
        expanded.removeGroup("mine", paths: paths)
        assert(!expanded.groups.contains { $0.id == "mine" })
        assert(expanded.files[paths[0]]?.groupID == WorkspaceLayout.ungrouped.id)
        assert(expanded.files[paths[0]]?.title == "Evaluation")
        var invalid = custom
        invalid.groups.append(custom.groups[0]); assert(!invalid.isValid())
        invalid = custom; invalid.groups[0].name = "  "; assert(!invalid.isValid())
        invalid = custom; invalid.version = 2; assert(!invalid.isValid())
        invalid = custom; invalid.files["../outside.tex"] = WorkspaceFileSettings(); assert(!invalid.isValid())
        print("PASS: dynamic folder groups, source headings, custom labels/order/assignments, round-trip persistence, new-file placement, group removal and invalid layout rejection.")
    }
}
