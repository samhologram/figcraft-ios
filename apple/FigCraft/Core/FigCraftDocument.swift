import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import FigCraftKit

extension UTType {
    /// `.figcraft` (exported by the app).
    nonisolated static let figcraftDocument = UTType(exportedAs: "ca.hologram.figcraft.document")
    /// Figma `.fig` (imported, opened read-only: saving writes a `.figcraft`).
    nonisolated static let figmaFig = UTType(importedAs: "com.figma.fig")
}

/// A FigCraft file: one `.figcraft` file whose bytes the engine reads and writes. One engine session per document.
final class FigCraftDocument: ReferenceFileDocument, @unchecked Sendable {
    typealias Snapshot = Data

    static var readableContentTypes: [UTType] { [.figcraftDocument, .figmaFig] }
    static var writableContentTypes: [UTType] { [.figcraftDocument] }

    /// The observable editor state of this document (created on the main actor).
    let model: EditorModel

    /// New document: blank, or the demo content when launched with `-FigCraftDemo`.
    init() {
        let model = MainActor.assumeIsolated { () -> EditorModel in
            let dark = UITraitCollection.current.userInterfaceStyle == .dark
            if DemoSeeder.isEnabled {
                return EditorModel(handle: DemoSeeder.makeHandle(dark: dark), demoReady: true)
            }
            return EditorModel(handle: DocumentHandle.newDocument(name: "Untitled", dark: dark))
        }
        self.model = model
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let name = configuration.file.filename.map { ($0 as NSString).deletingPathExtension } ?? "Untitled"
        let handle: DocumentHandle
        do {
            handle = try DocumentHandle.open(data: data, name: name)
        } catch {
            throw NSError(domain: "ca.hologram.figcraft", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: EditorModel.message(of: error)])
        }
        // A demo file written by the auto-create path is already seeded.
        let demo = DemoSeeder.autoCreate && configuration.file.filename?.hasPrefix("FigCraftDemo") == true
        self.model = MainActor.assumeIsolated { EditorModel(handle: handle, demoReady: demo) }
    }

    func snapshot(contentType: UTType) throws -> Data {
        let handle = model.handle
        do {
            return try handle.saveBytes()
        } catch {
            throw NSError(domain: "ca.hologram.figcraft", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: EditorModel.message(of: error)])
        }
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
