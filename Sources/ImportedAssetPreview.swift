import SwiftUI
import PDFKit

struct ImportedPDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        view.setAccessibilityLabel(L("Imported PDF preview"))
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

struct ImportedFilePreview: View {
    let file: ReportFile
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: file.isTable ? "tablecells" : "doc").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(file.name).font(.headline).lineLimit(3).multilineTextAlignment(.center)
            Text(file.isTable ? L("Open this spreadsheet in its default app.") : L("Open this file in its default app to view it."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
