import SwiftUI

struct BibliographyEditTarget: Identifiable {
    let entry: BibliographyEntry
    let source: String
    var id: String { entry.id }
}

struct BibliographyEditor: View {
    @ObservedObject var store: ReportStore
    @State private var raw = false
    @State private var editing: BibliographyEditTarget?
    var bibliography: Bibliography { Bibliography(store.text) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !raw { Text("\(bibliography.entries.count) kaynak").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                Picker("Kaynakça görünümü", selection: $raw) {
                    Text("Kaynaklar").tag(false)
                    Text("BibTeX").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
            }.padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            if raw {
                CodeEditor(store: store)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if bibliography.hasUnparsedEntries {
                            Label("Bazı kayıtlar okunamadı. BibTeX görünümünden metni kontrol edebilirsin.", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if bibliography.entries.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: "books.vertical").font(.system(size: 28)).foregroundStyle(.secondary)
                                Text("Kaynakların burada görünecek").font(.headline)
                                Text("BibTeX kayıtları başlık, yazar ve yayın bilgileriyle düzenli bir liste olarak gösterilir.")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                Button("BibTeX’i Aç") { raw = true }
                            }.padding(.vertical, 24)
                        }
                        ForEach(bibliography.entries) { entry in
                            entryCard(entry)
                        }
                    }.padding(18)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: store.jumpRevision) { _, _ in if store.jumpRange != nil { raw = true } }
        .onAppear { if store.jumpRange != nil { raw = true } }
        .sheet(item: $editing) { target in
            BibliographyEntryForm(target: target) { values in
                store.editBibliography(target.entry, original: target.source, values: values)
            } openRaw: {
                editing = nil
                raw = true
                store.jumpRange = target.entry.range
                store.jumpRevision += 1
            }
        }
    }

    private func entryCard(_ entry: BibliographyEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.typeLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !entry.value("year").isEmpty { Text(entry.value("year")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
            }
            Text(entry.title).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !entry.authors.isEmpty { Text(entry.authors).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            if !entry.publication.isEmpty { Text(entry.publication).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            let metadata = [entry.value("volume").isEmpty ? "" : "Cilt " + entry.value("volume"), entry.value("number").isEmpty ? "" : "Sayı " + entry.value("number"), entry.value("pages").isEmpty ? "" : "s. " + entry.value("pages").replacingOccurrences(of: "--", with: "–")].filter { !$0.isEmpty }.joined(separator: " · ")
            if !metadata.isEmpty { Text(metadata).font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack(spacing: 14) {
                if let doi = destination(entry.value("doi"), doi: true) { Link("DOI", destination: doi).font(.system(size: 12)) }
                if let url = destination(entry.value("url").isEmpty ? entry.value("howpublished") : entry.value("url")) { Link("Kaynağı Aç", destination: url).font(.system(size: 12)) }
                Spacer(minLength: 8)
                Button("Düzenle") { editing = BibliographyEditTarget(entry: entry, source: store.text) }.controlSize(.small)
            }
            Text(entry.key).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func destination(_ value: String, doi: Bool = false) -> URL? {
        guard !value.isEmpty else { return nil }
        let address = doi && !["https://", "http://"].contains(where: { value.lowercased().hasPrefix($0) }) ? "https://doi.org/" + value : value
        guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

struct BibliographyEntryForm: View {
    @Environment(\.dismiss) private var dismiss
    let target: BibliographyEditTarget
    let save: ([String: String]) -> String?
    let openRaw: () -> Void
    @State private var values: [String: String]
    @State private var error: String?

    init(target: BibliographyEditTarget, save: @escaping ([String: String]) -> String?, openRaw: @escaping () -> Void) {
        self.target = target; self.save = save; self.openRaw = openRaw
        _values = State(initialValue: Dictionary(target.entry.fields.map { ($0.name, Bibliography.display($0.value)) }, uniquingKeysWith: { first, _ in first }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Kaynağı Düzenle").font(.title3).fontWeight(.semibold)
                    Text(target.entry.typeLabel + " · " + target.entry.key).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("BibTeX’i Aç", action: openRaw).controlSize(.small)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(target.entry.fields) { field in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(field.label).font(.system(size: 12, weight: .medium))
                            if field.editable {
                                TextField(field.label, text: Binding(get: { values[field.name] ?? "" }, set: { values[field.name] = $0 }), axis: .vertical)
                                    .textFieldStyle(.roundedBorder).lineLimit(1...6)
                                if field.name == "author" || field.name == "editor" {
                                    Text("Birden fazla kişi arasında ‘and’ kullan.").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            } else {
                                Text(Bibliography.display(field.value)).font(.system(size: 13)).textSelection(.enabled)
                                Text("Bu alan bir BibTeX ifadesi kullanıyor. Değiştirmek için BibTeX’i aç.").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.red) }
                }.padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Uygula") {
                    error = save(values)
                    if error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width: 520, height: 570).background(Color(nsColor: .windowBackgroundColor))
    }
}
