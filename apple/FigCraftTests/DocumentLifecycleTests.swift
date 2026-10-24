import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@preconcurrency import FigCraftKit
@testable import FigCraft

/// DocumentGroup creates and reads ReferenceFileDocument values away from the main actor.
struct DocumentLifecycleTests {
    @Test @MainActor func photoCreatesVisibleImageLayerAndNativeFile() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3), format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        }
        let bytes = try await Task.detached {
            let document = try FigCraftDocument.fromPhoto(png)
            return try document.snapshot(contentType: .figcraftDocument)
        }.value
        #expect(!bytes.isEmpty)
        let reopened = try DocumentHandle.open(data: bytes, name: "Photo.figcraft")
        let layer = try #require(reopened.layers().first { $0.kind == "rectangle" })
        let node = try #require(JSONBridge.decodeObject(try reopened.nodeJson(id: layer.id)))
        #expect((node["width"] as? NSNumber)?.doubleValue == 2)
        #expect((node["height"] as? NSNumber)?.doubleValue == 3)
        let fills = try #require(node["fills"] as? [[String: Any]])
        #expect(fills.contains { ($0["type"] as? String)?.uppercased() == "IMAGE" })
    }

    @Test @MainActor func photoCopySurvivesNativeReadEditAndReimport() async throws {
        let png = testPNG(.blue)
        let source = FigNativeCopyMap.photoSourceKey(data: png)
        let prepared = try await Task.detached { try FigCraftDocument.fromPhoto(png) }.value
        let alias = try prepared.snapshot(contentType: .figcraftDocument)
        let copy = try #require(FigNativeCopyMap.existingCopy(for: source))
        defer { try? FileManager.default.removeItem(at: copy) }
        let appFolder = try FigCloudContainer.documentsFolder()
        #expect(copy.deletingLastPathComponent().standardizedFileURL == appFolder.standardizedFileURL)
        #expect(try Data(contentsOf: copy) != png)

        let read = try FigCraftDocument(data: alias, name: "Untitled.figcraft", demoEnabled: false)
        _ = read.model.run("shape.rectangle", ["x": 5, "y": 6, "width": 20, "height": 30])
        let browserWrapper = try read.fileWrapper(
            snapshot: read.snapshot(contentType: .figcraftDocument),
            existingFile: FileWrapper(regularFileWithContents: alias)
        )
        #expect(browserWrapper.regularFileContents == alias)
        let edited = try Data(contentsOf: copy)
        let editedHandle = try DocumentHandle.open(data: edited, name: "Photo.figcraft")
        #expect(editedHandle.layers().filter { $0.kind == "rectangle" }.count == 2)
        let fresh = try FigCraftDocument(data: alias, name: "Untitled.figcraft", demoEnabled: false)
        #expect(fresh.model.layers.filter { $0.kind == "rectangle" }.count == 2)

        let reimported = try FigCraftDocument.fromPhoto(png)
        #expect(FigNativeCopyMap.existingCopy(for: source) == copy)
        #expect(reimported.model.layers.filter { $0.kind == "rectangle" }.count == 2)

        // Opening the app-owned native file itself must save the edited bytes, not restore its old wrapper.
        let own = try FigCraftDocument(data: edited, name: copy.lastPathComponent, demoEnabled: false)
        own.setBrowserURL(copy)
        _ = own.model.run("shape.rectangle", ["x": 30, "y": 40, "width": 9, "height": 11])
        let ownWrapper = try own.fileWrapper(
            snapshot: own.snapshot(contentType: .figcraftDocument),
            existingFile: FileWrapper(regularFileWithContents: edited)
        )
        let ownSaved = try #require(ownWrapper.regularFileContents)
        let ownHandle = try DocumentHandle.open(data: ownSaved, name: "Photo.figcraft")
        #expect(ownHandle.layers().filter { $0.kind == "rectangle" }.count == 3)
        #expect(try Data(contentsOf: copy) == ownSaved)
    }

    @Test @MainActor func filesImageKeepsOriginalAndReusesEditedCopy() throws {
        let png = testPNG(.green)
        let key = FigNativeCopyMap.sourceKey(name: "Source.png", data: png)
        let opened = try FigCraftDocument(data: png, name: "Source.png", demoEnabled: false, contentType: .png)
        let copy = try #require(FigNativeCopyMap.existingCopy(for: key))
        defer { try? FileManager.default.removeItem(at: copy) }
        let appFolder = try FigCloudContainer.documentsFolder()
        #expect(copy.deletingLastPathComponent().standardizedFileURL == appFolder.standardizedFileURL)
        _ = opened.model.run("shape.rectangle", ["x": 1, "y": 2, "width": 12, "height": 15])
        let browserWrapper = try opened.fileWrapper(
            snapshot: opened.snapshot(contentType: .figcraftDocument),
            existingFile: FileWrapper(regularFileWithContents: png)
        )
        #expect(browserWrapper.regularFileContents == png)
        let edited = try Data(contentsOf: copy)
        let editedHandle = try DocumentHandle.open(data: edited, name: "Source.figcraft")
        #expect(editedHandle.layers().filter { $0.kind == "rectangle" }.count == 2)
        let reopened = try FigCraftDocument(data: png, name: "Source.png", demoEnabled: false, contentType: .png)
        #expect(FigNativeCopyMap.existingCopy(for: key) == copy)
        #expect(reopened.model.layers.filter { $0.kind == "rectangle" }.count == 2)
    }

    @MainActor private func testPNG(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 3, height: 2), format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        }
    }

    @Test func createSnapshotReadSnapshotOffMain() async throws {
        let document = await Task.detached { FigCraftDocument() }.value
        await MainActor.run {
            _ = document.model.run("shape.rectangle", ["x": 10, "y": 20, "width": 100, "height": 50])
        }
        let bytes = try await Task.detached {
            return try document.snapshot(contentType: .figcraftDocument)
        }.value
        #expect(!bytes.isEmpty)

        let reopened = try await Task.detached {
            let document = try FigCraftDocument(data: bytes, name: "Untitled")
            let roundtrip = try document.snapshot(contentType: .figcraftDocument)
            return (document, roundtrip)
        }.value
        #expect(!reopened.1.isEmpty)
        let original = try DocumentHandle.open(data: bytes, name: "Untitled")
        let copy = try DocumentHandle.open(data: reopened.1, name: "Untitled")
        let originalShape = try #require(original.layers().first { $0.kind == "rectangle" })
        let copyShape = try #require(copy.layers().first { $0.kind == "rectangle" })
        #expect(copy.layers().count == original.layers().count)
        #expect(copyShape.id == originalShape.id)
        #expect(copyShape.name == originalShape.name)
        let before = try #require(JSONBridge.decodeObject(try original.nodeJson(id: originalShape.id)))
        let after = try #require(JSONBridge.decodeObject(try copy.nodeJson(id: copyShape.id)))
        for key in ["x", "y", "width", "height"] {
            #expect((before[key] as? NSNumber)?.doubleValue == (after[key] as? NSNumber)?.doubleValue)
        }
        #expect((after["width"] as? NSNumber)?.doubleValue == 100)
        #expect((after["height"] as? NSNumber)?.doubleValue == 50)
        await MainActor.run {
            #expect(!reopened.0.model.isDemoReady)
        }
    }

    @Test func seededUntitledReadbackRetainsRequiredPrototypeContent() async throws {
        let seeded = try DemoSeeder.makeHandle(dark: false)
        let bytes = try seeded.saveBytes()
        let reopened = try await Task.detached {
            let document = try FigCraftDocument(data: bytes, name: "Untitled", demoEnabled: true)
            return (document, try document.snapshot(contentType: .figcraftDocument))
        }.value
        let readHandle = try DocumentHandle.open(data: reopened.1, name: "Untitled")
        #expect(DemoSeeder.isReady(readHandle))
        await MainActor.run { #expect(reopened.0.model.isDemoReady) }
    }
}
