import Foundation

@main struct BibliographyChecks {
    static func main() throws {
        let source = #"""
        % Notes and directives must survive field edits.
        @string{venue = "A Journal"}
        @preamble{"prefix"}
        @comment{keep {nested} content}
        @article{accented,
          title = {A {Nested} Title, with commas},
          author = {Michael V{\"o}tter and Emilia G{\'o}mez},
          year = 2024,
          journal = venue # " supplement",
          customfield = {Preserve {this} exactly},
          url = {https://example.org/a_b?q=x\&q=y}
        }
        @book(quoted,
          title = "A {Book} Title",
          year = "2023",
          publisher = {Example Press}
        )
        @unusual{unknown, title={Unknown type}, extra={A field}}
        """#
        let doc = Bibliography(source)
        assert(!doc.hasUnparsedEntries && doc.entries.count == 3)
        let entry = doc.entries[0]
        assert(entry.title == "A Nested Title, with commas")
        assert(entry.authors.contains("Vötter") && entry.authors.contains("Gómez"))
        assert(!entry.fields.first { $0.name == "journal" }!.editable)
        assert(doc.entries[2].typeLabel == "unusual")
        let unchanged = Dictionary(entry.fields.map { ($0.name, Bibliography.display($0.value)) }, uniquingKeysWith: { a, _ in a })
        assert(Bibliography.replacing(entry, in: source, values: unchanged) == source)
        let changed = Bibliography.replacing(entry, in: source, values: ["title":"Yeni başlık 🎵 & % _ {özel}", "year":"2026"])
        let updated = Bibliography(changed)
        assert(!updated.hasUnparsedEntries)
        assert(updated.entries[0].title == "Yeni başlık 🎵 & % _ {özel}")
        assert(updated.entries[0].value("year") == "2026")
        assert(changed.contains("customfield = {Preserve {this} exactly}"))
        assert(changed.contains("@string{venue = \"A Journal\"}") && changed.contains("journal = venue # \" supplement\""))
        assert(changed.contains("@comment{keep {nested} content}"))
        let quoted = Bibliography.replacing(doc.entries[1], in: source, values: ["title":"A \"Quoted\" Title"])
        let quotedDoc = Bibliography(quoted)
        assert(!quotedDoc.hasUnparsedEntries && quotedDoc.entries[1].title == "A \"Quoted\" Title")
        assert(Bibliography("@article{broken, title={Missing close}").hasUnparsedEntries)
        assert(Bibliography("% no entries").entries.isEmpty)
        assert(Bibliography.display(#"{\url{https://example.org/a_b}}"#) == "https://example.org/a_b")
        assert(Bibliography.display(Bibliography.encode("a~b\\c{d}")) == "a~b\\c{d}")
        if CommandLine.arguments.count > 1 {
            let actual = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            let parsed = Bibliography(actual)
            assert(!parsed.hasUnparsedEntries && !parsed.entries.isEmpty)
            for item in parsed.entries {
                assert(!item.title.isEmpty)
                let original = Dictionary(item.fields.map { ($0.name, Bibliography.display($0.value)) }, uniquingKeysWith: { a, _ in a })
                assert(Bibliography.replacing(item, in: actual, values: original) == actual)
            }
            print(parsed.entries[0].authors)
        }
        print("PASS: bibliography types, nested/quoted values, TeX accents, unknown fields/macros, source-preserving edits, Unicode/special characters, malformed input and actual reference file.")
    }
}
