import XCTest

/// Focused regression for selecting a panel that is already present, collapsed, or off the visible strip.
@MainActor
final class PanelDockUITests: FigCraftUITestCase {
    func testAddMenuKeepsSelectedPanelVisible() {
        launchDemo(dark: false)
        let ready = element("demoReady")
        guard openNewDesignIfNeeded() else { return }
        XCTAssertTrue(ready.waitForExistence(timeout: 30), "New Design did not open the demo document")
        XCTAssertTrue(element("canvas").waitForExistence(timeout: 10), "The demo canvas did not open")
        guard isPad else { return }
        if !element("inspector").exists { XCTAssertTrue(tap("inspector.toggle")) }

        XCTAssertTrue(tap("panels.menu.trailing"), "Inspector add menu must be reachable")
        XCTAssertTrue(tap("panels.show.prototype"), "Prototype must be in the add menu")
        XCTAssertTrue(canTap(element("panel.prototype")), "Opening Prototype must leave its tab visible")

        XCTAssertTrue(tap("panelHeader.prototype.collapse"))
        XCTAssertEqual(element("panelHeader.prototype.collapse").label, "Expand")
        XCTAssertTrue(tap("panels.menu.trailing"))
        XCTAssertTrue(tap("panels.show.prototype"), "Reopening a collapsed panel must expand it")
        XCTAssertTrue(canTap(element("panel.prototype")), "Reopening must scroll its tab into view")
        XCTAssertEqual(element("panelHeader.prototype.collapse").label, "Collapse")

        XCTAssertTrue(tap("panels.menu.trailing"))
        XCTAssertTrue(tap("panels.show.prototype"), "Reopening the selected panel must keep it")
        XCTAssertTrue(canTap(element("panel.prototype")))
        XCTAssertTrue(element("section.flows").exists || element("section.interactions").exists,
                      "The selected panel's content must remain mounted")
    }
}
