import SwiftUI
import UniformTypeIdentifiers
import ImageIO
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

    /// UniFFI's handle serializes engine access and can be used by DocumentGroup on a background thread.
    private let handle: DocumentHandle
    private let demoReady: Bool
    private let initError: String?
    @MainActor private var cachedModel: EditorModel?

    /// The scene asks for the model on the main actor, after DocumentGroup creates or reads the file.
    @MainActor var model: EditorModel {
        if let cachedModel { return cachedModel }
        let made = EditorModel(handle: handle, demoReady: demoReady)
        made.lastError = initError
        cachedModel = made
        return made
    }

    /// New document: blank, or the demo content when launched with `-FigCraftDemo`.
    init() {
        // A document has a stable light page colour; SwiftUI chrome follows the scene appearance.
        // No UIKit trait or main-actor state is read in this off-main DocumentGroup initializer.
        if DemoSeeder.isEnabled {
            do {
                let seeded = try DemoSeeder.makeHandle(dark: false)
                handle = seeded
                demoReady = true
                initError = nil
            } catch {
                NSLog("FigCraftDemo: creation failed: %@", error.localizedDescription)
                handle = DocumentHandle.newDocument(name: "Untitled", dark: false)
                demoReady = false
                initError = error.localizedDescription
            }
        } else {
            handle = DocumentHandle.newDocument(name: "Untitled", dark: false)
            demoReady = false
            initError = nil
        }
    }

    required convenience init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let name = configuration.file.filename.map { ($0 as NSString).deletingPathExtension } ?? "Untitled"
        try self.init(data: data, name: name)
    }

    /// The same read path, exposed to unit tests because SwiftUI does not expose ReadConfiguration's initializer.
    init(data: Data, name: String, demoEnabled: Bool = DemoSeeder.isEnabled) throws {
        do {
            handle = try DocumentHandle.open(data: data, name: name)
        } catch {
            throw NSError(domain: "ca.hologram.figcraft", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: EditorModel.message(of: error)])
        }
        demoReady = demoEnabled && DemoSeeder.isReady(handle)
        initError = nil
    }

    /// Prepare a native design from a Photos selection before DocumentGroup creates a file.
    /// ImageIO handles formats such as HEIC and applies the source orientation; the engine receives PNG.
    static func fromPhoto(_ data: Data) throws -> FigCraftDocument {
        guard !data.isEmpty, data.count <= 256 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw PhotoCreationError.invalidImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 16_384
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0 else { throw PhotoCreationError.invalidImage }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)
        else { throw PhotoCreationError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), png.length > 0, png.length <= 256 * 1024 * 1024
        else { throw PhotoCreationError.invalidImage }
        let handle = try DocumentHandle.open(data: png as Data, name: "Photo.png")
        guard handle.layers().contains(where: { $0.kind == "rectangle" }),
              !(try handle.saveBytes()).isEmpty else { throw PhotoCreationError.invalidImage }
        return FigCraftDocument(preparedHandle: handle)
    }

    private init(preparedHandle: DocumentHandle) {
        handle = preparedHandle
        demoReady = false
        initError = nil
    }

    func snapshot(contentType: UTType) throws -> Data {
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
