import Foundation
import Testing
import UniformTypeIdentifiers
@preconcurrency import FigCraftKit
@testable import FigCraft

/// DocumentGroup creates and reads ReferenceFileDocument values away from the main actor.
struct DocumentLifecycleTests {
    @Test func createSnapshotReadSnapshotOffMain() async throws {
        let bytes = try await Task.detached {
            let document = FigCraftDocument()
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
        #expect(original.layers().count == copy.layers().count)
        await MainActor.run {
            #expect(reopened.0.model.state.revision == copy.state().revision)
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
