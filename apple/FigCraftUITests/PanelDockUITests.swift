import XCTest

/// Focused regression for selecting a panel that is already present, collapsed, or off the visible strip.
@MainActor
final class PanelDockUITests: FigCraftUITestCase {
    func testToolbarSidebarRestoresSelectedPanel() {

        continueAfterFailure = false
        defer {
            let evidence = XCTAttachment(string: app.debugDescription)
            evidence.name = "sidebar-toggle-hierarchy"; evidence.lifetime = .keepAlways; add(evidence)
        }
        func waitState(_ message: String, _ check: @escaping () -> Bool) {
            let predicate = NSPredicate { _, _ in check() }
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: nil)], timeout: 8), .completed, message)
        }

        launchDemo(dark: false)
        XCTAssertTrue(openNewDesignIfNeeded(), "Fixture: foreground seeded design must open")
        XCTAssertTrue(element("demoReady").waitForExistence(timeout: 30), "Fixture: seeded content is required")
        let toggle = isPad ? "inspector.toggle" : "panels.toggle"
        func openPrototype() {
            if isPad {
                if !element("inspector").isHittable { XCTAssertTrue(tap(toggle)) }
                XCTAssertTrue(tap("panels.menu.trailing"))
                XCTAssertTrue(tap("panels.show.prototype"))
            } else { XCTAssertTrue(tap("phone.prototype")) }
        }
        func shown() -> Bool {
            let tab = element("panel.prototype")
            return tab.isHittable && tab.isSelected && (isPad
                ? element("panelHeader.prototype.collapse").label == "Collapse"
                : element("sheet.close").isHittable)
        }
        openPrototype()
        waitState("Prototype must be foreground and reachable", shown)
        XCTAssertTrue(tap(toggle), "Toolbar must hide panels")
        waitState("Prototype must no longer be interactive", { !shown() })
        XCTAssertTrue(tap(toggle), "Toolbar must restore panels")
        waitState("Restoring must preserve Prototype", shown)
        XCTAssertTrue(tap(toggle))
        waitState("Panels must hide before reopening", { !shown() })
        // Compact action row opens the hidden sheet; wide Add menu requires restoring its dock first.
        openPrototype()
        waitState("Reopening must reveal Prototype", shown)
    }

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
