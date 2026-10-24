import Foundation
import Testing
@preconcurrency import FigCraftKit
@testable import FigCraft

/// Smoke tests of the Rust bridge and the Swift core as the app uses them.
@MainActor
struct BridgeSmokeTests {
    private func rectangle(_ handle: DocumentHandle) throws {
        _ = try handle.execute(id: "shape.rectangle", paramsJson: "{\"x\":10,\"y\":10,\"width\":100,\"height\":50}")
    }

    @Test func catalogsAreLoaded() {
        #expect(!commandCatalog().isEmpty)
        #expect(menuLayout().contains { $0.title == "File" })
        #expect(!toolGroups().isEmpty)
        let catalog = CommandCatalog.shared
        #expect(!catalog.commands.isEmpty)
        #expect(!catalog.toolGroups.isEmpty)
        #expect(catalog.isKnown("shape.rectangle"))
    }

    @Test func executeChangesLayers() throws {
        let handle = DocumentHandle.newDocument(name: "T", dark: false)
        let before = handle.layers().count
        try rectangle(handle)
        #expect(handle.layers().count == before + 1)
    }

    @Test func undoRedoMovesHistory() throws {
        let handle = DocumentHandle.newDocument(name: "T", dark: false)
        let start = handle.state().historyId
        try rectangle(handle)
        let after = handle.state().historyId
        #expect(after != start)
        #expect(handle.state().canUndo)
        _ = try handle.undo()
        #expect(handle.state().historyId != after)
        #expect(handle.state().canRedo)
        _ = try handle.redo()
        #expect(handle.state().canUndo)
    }

    @Test func renderReturnsPixels() throws {
        let handle = DocumentHandle.newDocument(name: "T", dark: false)
        handle.setViewport(width: 200, height: 150)
        try rectangle(handle)
        let image = try handle.render(widthPx: 400, heightPx: 300, scale: 2)
        #expect(Int(image.width) == 400 && Int(image.height) == 300)
        #expect(image.rgba.count == 400 * 300 * 4)
        #expect(PixelFrame(image)?.makeCGImage() != nil)
    }

    @Test func saveBytesRoundTrips() throws {
        let handle = DocumentHandle.newDocument(name: "T", dark: false)
        try rectangle(handle)
        try rectangle(handle)
        let count = handle.layers().count
        let data = try handle.saveBytes()
        #expect(!data.isEmpty)
        let reopened = try DocumentHandle.open(data: data, name: "T")
        #expect(reopened.layers().count == count)
    }

    @Test func demoSeederBuildsFlow() throws {
        let handle = try DemoSeeder.makeHandle(dark: false)
        let frames = handle.layers().filter { $0.parent == nil && $0.kind == "frame" }
        #expect(frames.count >= 2)
        let first = try #require(frames.first)
        let json = try #require(JSONBridge.decodeObject(try handle.nodeJson(id: first.id)))
        let interactions = json["interactions"] as? [Any]
        #expect((interactions?.count ?? 0) >= 1 || hasInteraction(handle, frames: frames))
    }

    /// The click-navigate sits on a button-like layer inside the first frame, so look at its descendants.
    private func hasInteraction(_ handle: DocumentHandle, frames: [LayerRow]) -> Bool {
        for row in handle.layers() {
            guard let text = try? handle.nodeJson(id: row.id),
                  let json = JSONBridge.decodeObject(text),
                  let list = json["interactions"] as? [Any], !list.isEmpty else { continue }
            return true
        }
        return false
    }

    @Test func presenterTapNavigates() throws {
        let handle = try DemoSeeder.makeHandle(dark: false)
        let presenter = try handle.presenter(start: nil)
        let start = presenter.state()
        let spot = try #require(presenter.hotspots().first)
        _ = presenter.tap(x: spot.x + spot.width / 2, y: spot.y + spot.height / 2)
        let after = presenter.state()
        #expect(after.frame != start.frame)
        #expect(after.canGoBack)
        #expect(presenter.back())
        #expect(presenter.state().frame == start.frame)
        let frame = try presenter.render(widthPx: 200, heightPx: 400)
        #expect(frame.rgba.count == Int(frame.width) * Int(frame.height) * 4)
    }

    @Test func modelRunsCommandsAndTracksHistory() {
        let model = EditorModel(handle: DocumentHandle.newDocument(name: "T", dark: false))
        let before = model.layers.count
        model.run("shape.rectangle", ["x": 0, "y": 0, "width": 40.0, "height": Double.nan])
        // Junk (non-finite) params never crash; either the command ran or an error was reported.
        #expect(model.layers.count == before + 1 || model.lastError != nil)
        model.run("shape.rectangle", ["x": 5, "y": 5, "width": 30, "height": 30])
        #expect(model.state.canUndo)
        model.undo()
        model.redo()
        model.run("no.such.command")
        #expect(model.lastError != nil)
    }

    @Test func shortcutParsing() {
        #expect(CommandCatalog.parseShortcut("Cmd+Shift+R") != nil)
        #expect(CommandCatalog.parseShortcut("Cmd++") != nil)
        #expect(CommandCatalog.parseShortcut("F5") == nil)
    }
}
