import XCTest

/// Scenario in dark and light: demo document, select a layer, open each panel, change a field, open the palette,
/// present and tap through, close. Anything missing is recorded in the `-notes` attachment.
@MainActor
final class FigCraftUITests: FigCraftUITestCase {
    func testScenarioDark() throws { try scenario(dark: true) }
    func testScenarioLight() throws { try scenario(dark: false) }

    private func scenario(dark: Bool) throws {
        launchDemo(dark: dark)
        defer { flushNotes() }
        waitForDemo()

        // Select a layer.
        let layerQuery = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", "layer\\.[0-9]+"))
        if !isPad { tap("phone.layers"); pause(1) }
        if layerQuery.firstMatch.waitForExistence(timeout: 10) {
            let rows = layerQuery.allElementsBoundByIndex
            if let row = rows.dropFirst().first(where: { canTap($0) }) ?? rows.first(where: { canTap($0) }) { row.tap() } else { note("no hittable layer row") }
        } else { note("no layer.<id> rows") }
        pause(1)
        if !isPad { tap("sheet.close"); pause(1) }

        // Panels.
        if isPad {
            for panel in ["assets", "layers"] where !tap("panel.\(panel)") { note("panel.\(panel) unreachable") }
        } else {
            tap("phone.layers"); pause(1); tap("panel.assets"); pause(0.5); tap("panel.layers"); tap("sheet.close"); pause(1)
        }
        if !isPad { tap("phone.design"); pause(1) }
        for tab in ["prototype", "inspect", "design"] { tap("panel.\(tab)"); pause(0.7) }

        // Change a field.
        let field = element("control.opacity")
        if field.waitForExistence(timeout: 5), canTap(field) {
            field.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + "50\n")
            pause(1)
        } else { note("control.opacity not reachable") }
        if !isPad { tap("sheet.close"); pause(1) }

        // Palette.
        if tap("palette.open") {
            let search = element("palette.search")
            if search.waitForExistence(timeout: 5) { search.tap(); search.typeText("zoom") } else { note("palette.search missing") }
            pause(1)
            if !element("command.view.zoomFit").exists { note("command.view.zoomFit not listed for 'zoom'") }
            tap("palette.done")
            pause(1)
        }

        // Present.
        if tap("command.proto.present") {
            if element("present").waitForExistence(timeout: 10) {
                pause(2)
                let area = element("present")
                for p in [(0.5, 0.5), (0.5, 0.8), (0.3, 0.3)] {
                    area.coordinate(withNormalizedOffset: CGVector(dx: p.0, dy: p.1)).tap()
                    pause(1)
                }
                tap("present.back"); pause(1)
                tap("present.restart"); pause(1)
                tap("present.close")
                pause(1)
                if element("present").exists { note("present did not close") }
            } else { note("present never appeared") }
        }
        XCTAssertEqual(app.state, .runningForeground)
    }
}
