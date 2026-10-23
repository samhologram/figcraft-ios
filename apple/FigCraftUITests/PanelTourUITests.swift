import XCTest

/// Opens every panel (`panel.<id>`) and every inspector section through the real UI, acts on the first control
/// of each, and returns to a usable state. Only a crash fails; the rest is in the `-tour-summary` attachment.
@MainActor
final class PanelTourUITests: TourTestCase {
    static let panels = ["layers", "assets", "design", "prototype", "inspect"]
    static let designSections = ["position", "layout", "appearance", "fill", "stroke", "effects", "export"]

    func testPanelsPortrait() throws { try tour(landscape: false) }
    func testPanelsLandscape() throws { try tour(landscape: true) }

    private func tour(landscape: Bool) throws {
        startTour(name: "panels", landscape: landscape)
        defer { attachSummary(); flushNotes() }
        selectFirstLayer()
        for panel in Self.panels {
            if let only, !only.contains(panel) { continue }
            visit(panel)
        }
        // Text-only section: select a text layer if the document has one (looked up by name).
        record("section.text", element("section.text").exists ? "reached" : "not-reached", "only for text layers; shown when the selection is text")
        // Page section: nothing selected.
        _ = hit("tool.move").map { $0.tap() }
        closeOverlays()
        if canvas.exists {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap(); pause(0.8)
        }
        open("design")
        record("section.page", element("section.page").waitForExistence(timeout: 3) ? "reached" : "not-reached", "design tab with nothing selected")
        closeOverlays()
        _ = alive("end")
    }

    private func open(_ panel: String) {
        if !isPad {
            let sheet = ["layers": "phone.layers", "assets": "phone.layers", "design": "phone.design", "prototype": "phone.prototype", "inspect": "phone.design"][panel] ?? "phone.design"
            if !element("sheet.close").exists { tap(sheet); pause(1) }
        } else if ["layers", "assets"].contains(panel) { openSidebarIfNeeded() } else { openInspectorIfNeeded() }
        tap("panel.\(panel)")
        pause(0.8)
    }

    private func visit(_ panel: String) {
        let name = "panel.\(panel)"
        closeOverlays()
        open(panel)
        guard element(name).exists else { record(name, "not-reached", "tab missing"); return }
        pause(0.5)
        var detail: [String] = []
        var outcome = "reached"
        switch panel {
        case "layers":
            if let row = hit(prefix: "layer.") { row.tap(); detail.append("tapped \(row.identifier)"); outcome = "acted" }
            if let eye = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH '.visible'")).allElementsBoundByIndex.first(where: { canTap($0) }) {
                eye.tap(); pause(0.4); undoAll(max: 1); detail.append("toggled visibility, undone")
            }
            if let page = hit(prefix: "page.") { detail.append("pages listed: \(page.identifier)") }
        case "assets":
            detail.append(element("assets.empty").exists ? "no components on this page (empty state shown)" : "components listed")
            if let row = hit(prefix: "asset.") { row.tap(); outcome = "acted" }
        case "design":
            var missing: [String] = []
            for s in Self.designSections {
                let e = element("section.\(s)")
                if !e.exists { missing.append(s) }
            }
            if let f = hit("control.x") ?? hit("control.opacity") {
                f.tap()
                f.typeText("1\n")
                pause(0.6)
                outcome = "acted"; detail.append("typed into \(f.identifier)")
                undoAll(max: 2)
            }
            if !missing.isEmpty {
                // Scroll once and look again before calling a section missing.
                element("design.scroll").swipeUp(velocity: .slow); pause(0.5)
                missing = missing.filter { !element("section.\($0)").exists }
            }
            for s in Self.designSections { record("section.\(s)", missing.contains(s) ? "not-reached" : "reached", missing.contains(s) ? "not in the hierarchy after scrolling" : "") }
        case "prototype":
            detail.append(element("section.interactions").exists ? "interactions section" : (element("section.flows").exists ? "flows section" : "no section"))
            if let add = hit("command.proto.interaction.add") { add.tap(); pause(0.6); outcome = "acted"; detail.append("added interaction"); undoAll(max: 1) }
            else if let add = hit("command.proto.flow.add") { add.tap(); pause(0.6); outcome = "acted"; detail.append("tapped add flow"); undoAll(max: 1) }
        case "inspect":
            detail.append(element("section.properties").exists ? "properties listed" : "no properties section")
            if let t = hit("inspectCode.toggle") { t.tap(); pause(0.6); outcome = "acted"; detail.append("code toggled") }
        default: break
        }
        let alerts = dismissStrays()
        if !alive(name) { return }
        if !alerts.isEmpty { outcome = "refused"; detail.append("ALERT=" + alerts.joined(separator: " || ")) }
        record(name, outcome, detail.joined(separator: "; "))
    }
}
