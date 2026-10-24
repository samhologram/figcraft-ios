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
