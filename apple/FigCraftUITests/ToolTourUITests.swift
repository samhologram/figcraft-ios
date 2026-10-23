import XCTest

/// Selects every tool of the bridge's toolbar groups (`tool.<id>`; the list mirrors `crates/ui-egui/src/toolbar.rs`
/// GROUPS), drags on the canvas, then undoes. Only a crash fails; the rest is in the `-tour-summary` attachment.
@MainActor
final class ToolTourUITests: TourTestCase {
    static let groups: [(key: String, tools: [String])] = [
        ("move", ["move", "hand", "scale"]),
        ("frame", ["frame", "section", "slice"]),
        ("shape", ["rectangle", "line", "arrow", "ellipse", "polygon", "star"]),
        ("pen", ["pen", "pencil", "shapeBuilder"]),
        ("text", ["text"]),
        ("comment", ["comment"]),
    ]

    func testToolsPortrait() throws { try tour(landscape: false) }
    func testToolsLandscape() throws { try tour(landscape: true) }

    private func tour(landscape: Bool) throws {
        startTour(name: "tools", landscape: landscape)
        defer { attachSummary(); flushNotes() }
        for group in Self.groups {
            for tool in group.tools {
                if let only, !only.contains(tool) { continue }
                if let limit, items.count >= limit { return }
                visit(tool, siblings: group.tools)
            }
        }
    }

    /// The tool button, opening the group's flyout (long press on a sibling's button) when it is not shown.
    private func reveal(_ tool: String, siblings: [String]) -> XCUIElement? {
        if let e = hit("tool.\(tool)") { return e }
        // iPhone strip: scroll it.
        if !isPad, element("tool.\(tool)").exists {
            let strip = element("toolstrip")
            for _ in 0..<6 {
                strip.swipeLeft(velocity: .slow); pause(0.4)
                if let e = hit("tool.\(tool)") { return e }
            }
        }
        // iPad: the group's menu is the button of whichever sibling is shown.
        for s in siblings where s != tool {
            if let b = hit("tool.\(s)") {
                b.press(forDuration: 0.8)
                pause(0.6)
                if let e = hit("tool.\(tool)") { return e }
                dismissMenu()
            }
        }
        return nil
    }

    private func dismissMenu() { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap(); pause(0.4) }

    private func visit(_ tool: String, siblings: [String]) {
        let name = "tool.\(tool)"
        closeOverlays()
        undoAll(max: 6)
        guard let button = reveal(tool, siblings: siblings) else {
            record(name, "not-reached", element(name).exists ? "off-screen or covered" : "missing identifier")
            return
        }
        button.tap()
        pause(0.8)
        let target = canvas
        guard target.exists else { record(name, "reached", "selected; no canvas element to drag on"); return }
        switch tool {
        case "hand": drag(target, (0.3, 0.5), (0.6, 0.5))
        case "text", "comment": target.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).tap(); pause(0.5)
        case "pen", "pencil":
            drag(target, (0.3, 0.3), (0.6, 0.35)); drag(target, (0.6, 0.35), (0.4, 0.6))
        default: drag(target, (0.3, 0.3), (0.55, 0.5))
        }
        pause(0.6)
        let acted = element("undo").exists && element("undo").isEnabled
        let alerts = dismissStrays()
        if !alive(name) { return }
        undoAll(max: 6)
        if app.keyboards.count > 0 { app.keyboards.buttons["return"].firstMatch.tap() }
        if let first = alerts.first {
            record(name, "refused", first)
            note("\(name): \(alerts.joined(separator: " || "))")
        } else {
            record(name, acted ? "acted" : "reached", acted ? "drag changed the document" : "selected; the gesture made no undo step")
        }
        // Back to Move so the next tool starts from a known state.
        if let move = hit("tool.move") { move.tap(); pause(0.3) }
    }
}
