import SwiftUI
import UIKit

/// Export the selection (or the page) as PNG, SVG or PDF through the engine, then hand the file to the share sheet.
struct ExportSheet: View {
    let model: EditorModel

    enum Format: String, CaseIterable, Identifiable {
        case png, svg, pdf
        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
        var fileExtension: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var format: Format = .png
    @State private var fileURL: URL?
    @State private var preview: UIImage?
    @State private var working = false
    @State private var byteCount = 0

    private var scopeText: String {
        let n = model.state.selection.count
        if format == .pdf { return "All top-level frames of the file." }
        return n == 0 ? "The whole page." : "\(n) selected layer\(n == 1 ? "" : "s")."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(Format.allCases) { f in Text(verbatim: f.title).tag(f) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("export.format")
                } footer: {
                    Text(verbatim: scopeText)
                }
                if let preview, format == .png {
                    Section {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .accessibilityHidden(true)
                    }
                }
                Section {
                    if working {
                        HStack { ProgressView(); Text("Preparing\u{2026}") }
                    } else if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Share \(format.title) (\(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)))", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("export.share")
                    } else {
                        Text("Nothing to export.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { close() }
                        .accessibilityIdentifier("export.done")
                }
            }
            .task(id: format) { prepare() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("export.sheet")
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { model.showExport = false }
    }

    private func close() {
        model.showExport = false
        dismiss()
    }

    private func prepare() {
        working = true
        defer { working = false }
        fileURL = nil
        preview = nil
        let data: Data?
        switch format {
        case .png: data = model.exportPNG()
        case .svg: data = model.exportSVG()
        case .pdf: data = model.exportPDF()
        }
        guard let data, !data.isEmpty else { return }
        if format == .png { preview = UIImage(data: data) }
        byteCount = data.count
        let safe = model.state.name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let name = String(safe.prefix(60))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name.isEmpty ? "FigCraft" : name).\(format.fileExtension)")
        do {
            try data.write(to: url, options: .atomic)
            fileURL = url
        } catch {
            model.lastError = "Could not prepare the export: \(error.localizedDescription)"
        }
    }
}
