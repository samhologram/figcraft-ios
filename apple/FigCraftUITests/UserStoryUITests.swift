import XCTest

@MainActor
final class UserStoryUITests: FigCraftUITestCase {
    /// A designer selects artwork, edits its opacity, checks undo/redo, then opens Prototype without losing selection.
    func testEditLayerOpacityUndoRedoAndPrototypePortrait() {
        XCUIDevice.shared.orientation = .portrait
        launchDemo(dark: false)
        defer { attach("opacity-story-hierarchy", app.debugDescription); flushNotes("opacity-story-notes") }
        guard openNewDesignIfNeeded() else { return }
        XCTAssertTrue(element("demoReady").waitForExistence(timeout: 30), "The seeded design must open")
        XCTAssertTrue(element("canvas").exists)
        if isPad {
            if !element("layers.list").exists { XCTAssertTrue(tap("sidebar.toggle")) }
        } else { XCTAssertTrue(tap("phone.layers")) }
        XCTAssertTrue(tap("panel.layers"))
        let rows = app.buttons.matching(NSPredicate(format: "identifier MATCHES %@", #"layer\.[0-9]+"#))
        guard let layer = rows.allElementsBoundByIndex.first(where: { canTap($0) }) else {
            XCTFail("The demo design exposes no selectable artwork layer"); return
        }
        let selectedID = layer.identifier
        layer.tap()
        if !isPad { XCTAssertTrue(tap("sheet.close")) }

        func openDesign() {
            if isPad {
                if !element("inspector").exists { XCTAssertTrue(tap("inspector.toggle")) }
            } else { XCTAssertTrue(tap("phone.design")) }
            XCTAssertTrue(tap("panel.design"))
            for _ in 0..<8 {
                if hit("control.opacity") != nil { break }
                element("design.scroll").swipeUp()
            }
            XCTAssertNotNil(hit("control.opacity"), "Opacity must be reachable for the selected layer")
        }
        func closeDesign() {
            if isPad { XCTAssertTrue(tap("inspector.toggle")) }
            else { XCTAssertTrue(tap("sheet.close")) }
        }
        func opacity() -> Double? {
            guard let text = element("control.opacity").value as? String else { return nil }
            return Double(text.replacingOccurrences(of: "%", with: ""))
        }
        openDesign()
        guard let before = opacity() else { XCTFail("Opacity field has no numeric accessible value"); return }
        let target = before == 50 ? 60 : 50
        let field = element("control.opacity")
        let text = field.value as? String ?? ""
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count) + "\(target)\n")
        closeDesign() // commits focus changes and exposes toolbar undo on the phone
        openDesign()
        XCTAssertEqual(opacity(), Double(target), "The design must retain the submitted opacity")
        closeDesign()
        XCTAssertTrue(element("undo").isEnabled)
        XCTAssertTrue(tap("undo"))
        openDesign()
        XCTAssertEqual(opacity(), before, "Undo must restore the exact original opacity")
        closeDesign()
        XCTAssertTrue(element("redo").isEnabled)
        XCTAssertTrue(tap("redo"))
        openDesign()
        XCTAssertEqual(opacity(), Double(target), "Redo must restore the opacity edit")
        XCTAssertTrue(tap("panel.prototype"))
        XCTAssertTrue(canTap(element("panel.prototype")), "Selected Prototype tab must remain visible")
        XCTAssertTrue(element("section.flows").exists || element("section.interactions").exists,
                      "Prototype must show its actual editing controls")
        closeDesign()
        if isPad { if !element("layers.list").exists { XCTAssertTrue(tap("sidebar.toggle")) } }
        else { XCTAssertTrue(tap("phone.layers")) }
        XCTAssertTrue(element(selectedID).isSelected, "Panel switching must preserve the selected artwork")
        note("Opacity changed through native inspector, undone and redone; Prototype opened; artwork selection retained")
    }
}
