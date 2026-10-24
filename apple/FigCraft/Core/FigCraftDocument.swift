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

    static var readableContentTypes: [UTType] {
        [.figcraftDocument, .figmaFig, .png, .jpeg, .heic, .tiff, .gif, .webP, .image]
    }
    static var writableContentTypes: [UTType] { [.figcraftDocument] }

    /// UniFFI's handle serializes engine access and can be used by DocumentGroup on a background thread.
    private let handle: DocumentHandle
    private let demoReady: Bool
    private let initError: String?
    private let originalData: Data
    private let originalKey: String
    private let originalBaseName: String
    private let preserveBrowserFile: Bool
    private let openedOwnCopyName: Bool
    private let preparedSnapshot: Data?
    private let copyLock = NSLock()
    private let copyQueue = DispatchQueue(label: "ca.hologram.figcraft.nativecopy", qos: .utility)
    private var copyURL: URL?
    private var browserURL: URL?
    private var copyGeneration = 0
    @MainActor private var cachedModel: EditorModel?

    /// The scene asks for the model on the main actor, after DocumentGroup creates or reads the file.
    @MainActor var model: EditorModel {
        if let cachedModel { return cachedModel }
        let made = EditorModel(handle: handle, demoReady: demoReady)
        if !originalKey.isEmpty { made.onDirty = { [weak self] in self?.scheduleCopyWrite() } }
        made.lastError = initError
        cachedModel = made
        return made
    }

    /// New document: blank, or the demo content when launched with `-FigCraftDemo`.
    init() {
        originalData = Data()
        originalKey = ""
        originalBaseName = ""
        preserveBrowserFile = false
        openedOwnCopyName = false
        preparedSnapshot = nil
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
        try self.init(data: data,
                      name: configuration.file.filename ?? configuration.file.preferredFilename ?? "Untitled",
                      contentType: configuration.contentType)
    }

    /// The same read path, exposed to unit tests because SwiftUI does not expose ReadConfiguration's initializer.
    init(data: Data, name: String, demoEnabled: Bool = DemoSeeder.isEnabled,
         contentType: UTType = .figcraftDocument) throws {
        let fileName = (name as NSString).pathExtension.isEmpty
            ? "\(name).\(contentType.preferredFilenameExtension ?? "figcraft")" : name
        let native = contentType.conforms(to: .figcraftDocument)
            || (fileName as NSString).pathExtension.lowercased() == "figcraft"
        let preparedKey = native ? FigNativeCopyMap.preparedKey(data: data) : ""
        let preparedCopy = preparedKey.isEmpty ? nil : FigNativeCopyMap.existingCopy(for: preparedKey)
        // A user may open the app-owned copy itself in Files. Let DocumentGroup save that file normally;
        // returning its old FileWrapper after writing the copy would roll back the edit.
        let key = native ? (preparedCopy == nil ? "" : preparedKey)
            : FigNativeCopyMap.sourceKey(name: fileName, data: data)
        let copy = key.isEmpty ? nil : FigNativeCopyMap.existingCopy(for: key)
        let copyBytes = copy.flatMap { try? Data(contentsOf: $0) }
        let reopened = copyBytes.flatMap { try? DocumentHandle.open(data: $0, name: "Copy.figcraft") }
        do {
            if let reopened {
                handle = reopened
            } else if contentType.conforms(to: .image) {
                handle = try DocumentHandle.open(data: Self.normalizedPNG(data), name: "Image.png")
            } else {
                handle = try DocumentHandle.open(data: data, name: fileName)
            }
        } catch {
            throw NSError(domain: "ca.hologram.figcraft", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: EditorModel.message(of: error)])
        }
        demoReady = demoEnabled && DemoSeeder.isReady(handle)
        initError = nil
        originalKey = key
        originalData = key.isEmpty ? Data() : data
        originalBaseName = native && !key.isEmpty ? "Photo" : (fileName as NSString).deletingPathExtension
        preserveBrowserFile = !native || !key.isEmpty
        openedOwnCopyName = preparedCopy?.lastPathComponent == fileName
        preparedSnapshot = nil
        copyURL = copy
        if !key.isEmpty && reopened == nil { try writeNativeCopy() }
    }

    /// Prepare a native design from a Photos selection before DocumentGroup creates a file.
    /// ImageIO handles formats such as HEIC and applies the source orientation; the engine receives PNG.
    static func fromPhoto(_ data: Data) throws -> FigCraftDocument {
        let key = FigNativeCopyMap.photoSourceKey(data: data)
        let copy = FigNativeCopyMap.existingCopy(for: key)
        let copyBytes = copy.flatMap { try? Data(contentsOf: $0) }
        let reopened = copyBytes.flatMap { try? DocumentHandle.open(data: $0, name: "Photo.figcraft") }
        let handle = try reopened ?? DocumentHandle.open(data: normalizedPNG(data), name: "Photo.png")
        guard handle.layers().contains(where: { $0.kind == "rectangle" }) else { throw PhotoCreationError.invalidImage }
        let prepared = try handle.saveBytes()
        guard !prepared.isEmpty else { throw PhotoCreationError.invalidImage }
        let document = FigCraftDocument(preparedHandle: handle, key: key, copy: copy, snapshot: prepared)
        try document.writeNativeCopy()
        if let url = document.copyURL {
            FigNativeCopyMap.remember(url, for: FigNativeCopyMap.preparedKey(data: prepared))
        }
        return document
    }

    private static func normalizedPNG(_ data: Data) throws -> Data {
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
        return png as Data
    }

    private init(preparedHandle: DocumentHandle, key: String, copy: URL?, snapshot: Data) {
        handle = preparedHandle
        demoReady = false
        initError = nil
        originalData = Data()
        originalKey = key
        originalBaseName = "Photo"
        preserveBrowserFile = false
        openedOwnCopyName = false
        preparedSnapshot = snapshot
        copyURL = copy
    }

    func snapshot(contentType: UTType) throws -> Data {
        do {
            return try preparedSnapshot ?? handle.saveBytes()
        } catch {
            throw NSError(domain: "ca.hologram.figcraft", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: EditorModel.message(of: error)])
        }
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        try fileWrapper(snapshot: snapshot, existingFile: configuration.existingFile)
    }

    /// DocumentGroup may write back to a foreign browser URL. Keep that file byte-for-byte unchanged.
    func fileWrapper(snapshot: Data, existingFile: FileWrapper?) throws -> FileWrapper {
        guard !originalKey.isEmpty else { return FileWrapper(regularFileWithContents: snapshot) }
        let latest = try writeNativeCopy()
        copyLock.lock()
        let sameFile: Bool
        if let browserURL, let copyURL {
            sameFile = browserURL.standardizedFileURL == copyURL.standardizedFileURL
        } else {
            sameFile = openedOwnCopyName
        }
        copyLock.unlock()
        return preserveBrowserFile && !sameFile
            ? (existingFile ?? FileWrapper(regularFileWithContents: originalData))
            : FileWrapper(regularFileWithContents: latest)
    }

    @MainActor func setBrowserURL(_ url: URL?) {
        copyLock.lock(); browserURL = url; copyLock.unlock()
    }

    /// Save edited native state independently of DocumentGroup's delayed autosave.
    func scheduleCopyWrite() {
        copyLock.lock()
        copyGeneration += 1
        let generation = copyGeneration
        copyLock.unlock()
        copyQueue.asyncAfter(deadline: .now() + 0.8) { [self] in
            copyLock.lock()
            let current = copyGeneration == generation
            copyLock.unlock()
            if current { _ = try? writeNativeCopy() }
        }
    }

    func flushCopy() {
        guard !originalKey.isEmpty else { return }
        copyQueue.async { [self] in _ = try? writeNativeCopy() }
    }

    @discardableResult private func writeNativeCopy() throws -> Data {
        copyLock.lock(); defer { copyLock.unlock() }
        let url = try copyDestination()
        let latest = try handle.saveBytes()
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try latest.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
        FigNativeCopyMap.remember(url, for: originalKey)
        return latest
    }

    private func copyDestination() throws -> URL {
        if let copyURL { return copyURL }
        if let existing = FigNativeCopyMap.existingCopy(for: originalKey) {
            copyURL = existing
            return existing
        }
        let folder = try FigCloudContainer.documentsFolder()
        let base = (originalBaseName as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = base.isEmpty ? "Untitled" : base
        var candidate = folder.appending(path: "\(stem).figcraft")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(stem) \(number).figcraft")
            number += 1
        }
        copyURL = candidate
        return candidate
    }
}
