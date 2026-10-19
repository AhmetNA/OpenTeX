import SwiftUI

struct WorkspaceOrganizer: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ReportStore
    @State private var layout: WorkspaceLayout
    @State private var error: String?
    private let original: Data?
    private let root: URL
    private let files: [ReportFile]

    init(store: ReportStore) {
        self.store = store
        _layout = State(initialValue: store.workspace)
        original = store.workspaceSnapshot
        root = store.root
        files = store.files
    }

    private func title(_ group: WorkspaceGroup) -> String { group.localizeName ? L(group.name) : group.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Organize Files")).font(.title3).fontWeight(.semibold)
                Text(L("Create groups and choose where each file appears.")).font(.callout).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Groups")).font(.headline)
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(Array(layout.groups.enumerated()), id: \.element.id) { index, group in
                                VStack(alignment: .leading, spacing: 7) {
                                    TextField(L("Group name"), text: Binding(get: { title(group) }, set: { value in
                                        guard let i = layout.groups.firstIndex(where: { $0.id == group.id }) else { return }
                                        layout.groups[i].name = value
                                        layout.groups[i].localizeName = false
                                    })).textFieldStyle(.roundedBorder)
                                    HStack(spacing: 12) {
                                        Button { layout.groups.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                            .disabled(index == 0).help(L("Move group up"))
                                        Button { layout.groups.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                            .disabled(index == layout.groups.count - 1).help(L("Move group down"))
                                        Spacer()
                                        Button { layout.removeGroup(group.id, paths: files.map(\.path)) } label: { Image(systemName: "minus.circle") }
                                            .disabled(group.id == WorkspaceLayout.ungrouped.id).help(L("Remove group; keep its files in Ungrouped"))
                                    }.buttonStyle(.borderless).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.trailing, 6)
                    }
                    Button { layout.groups.append(WorkspaceGroup(id: UUID().uuidString, name: newGroupName())) } label: { Label(L("Add Group"), systemImage: "plus") }
                }.padding(18).frame(minWidth: 210, idealWidth: 230, maxWidth: 280)
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(L("Display name")).font(.headline); Spacer(); Text(L("Group")).font(.headline).frame(width: 170, alignment: .leading) }
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(files) { file in
                                HStack(alignment: .top, spacing: 14) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        TextField(file.title, text: Binding(get: { layout.files[file.path]?.title ?? "" }, set: { value in
                                            layout.files[file.path, default: WorkspaceFileSettings()].title = value.isEmpty ? nil : value
                                        })).textFieldStyle(.roundedBorder).help(L("Leave empty to use the source heading or filename"))
                                        Text(file.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                                    }
                                    Picker(L("Group"), selection: Binding(get: { layout.files[file.path]?.groupID ?? WorkspaceLayout.ungrouped.id }, set: { value in
                                        layout.files[file.path, default: WorkspaceFileSettings()].groupID = value
                                    })) {
                                        ForEach(layout.groups) { group in Text(title(group)).tag(group.id) }
                                    }.labelsHidden().frame(width: 170)
                                }
                            }
                        }.padding(.trailing, 6)
                    }
                }.padding(18).frame(minWidth: 430)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Groups organize the sidebar. Your files and PDF section order stay the same.")).font(.system(size: 11)).foregroundStyle(.secondary)
                if let error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Button(L("Use Automatic Groups")) { layout = .automatic(paths: files.map(\.path)) }
                    Spacer()
                    Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L("Apply")) {
                        error = store.saveWorkspace(layout, original: original, expectedRoot: root)
                        if error == nil { dismiss() }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(18)
        }.frame(width: 820, height: 640).background(Color(nsColor: .windowBackgroundColor))
    }

    private func newGroupName() -> String {
        let base = L("New Group")
        var name = base, number = 2
        let names = Set(layout.groups.map { title($0).lowercased() })
        while names.contains(name.lowercased()) { name = base + " " + String(number); number += 1 }
        return name
    }
}
