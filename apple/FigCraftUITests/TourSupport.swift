import XCTest

struct TourItem {
    let name: String
    /// reached / acted / not-reached / refused
    let outcome: String
    let detail: String
}

/// Shared driver of the coverage tours (tools, panels, commands). Every item is visited through the real UI; only a
/// crash (app no longer running) fails a test. Everything else lands in the `-tour-summary` text attachment.
/// Environment `TEST_RUNNER_TOUR_ONLY=a,b` limits the items, `TEST_RUNNER_TOUR_LIMIT=n` caps their number.
@MainActor
class TourTestCase: FigCraftUITestCase {
    var items: [TourItem] = []
    var summaryAttached = false
    var crashed = false

    var limit: Int? { ProcessInfo.processInfo.environment["TOUR_LIMIT"].flatMap { Int($0) } }
    var only: Set<String>? {
        guard let v = ProcessInfo.processInfo.environment["TOUR_ONLY"], !v.isEmpty else { return nil }
        return Set(v.split(separator: ",").map(String.init))
    }

    func startTour(name: String, landscape: Bool) {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        launchDemo(dark: false)
        continueAfterFailure = true
        prefix = "\(isPad ? "ipad" : "iphone")-\(landscape ? "landscape" : "portrait")-\(name)"
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        waitForDemo()
    }

    func record(_ name: String, _ outcome: String, _ detail: String = "") {
        items.append(TourItem(name: name, outcome: outcome, detail: detail))
        NSLog("TOUR %@ %@ %@", outcome, name, detail)
    }

    func attachSummary() {
        guard !summaryAttached else { return }
        summaryAttached = true
        var counts: [String: Int] = [:]
        for i in items { counts[i.outcome, default: 0] += 1 }
        var lines = ["\(prefix) tour summary", "items: \(items.count)  " + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "), ""]
        lines += items.map { "\($0.outcome.uppercased().padding(toLength: 12, withPad: " ", startingAt: 0)) \($0.name)  \($0.detail)" }
        lines += ["", "notes:"] + (notes.isEmpty ? ["none"] : notes)
        attach("tour-summary", lines.joined(separator: "\n"))
    }

    /// True while the app runs. After a crash the item is recorded, the test fails, and the app relaunches.
    func alive(_ item: String) -> Bool {
        if app.state == .runningForeground && app.windows.firstMatch.exists { return true }
        crashed = true
        record(item, "not-reached", "CRASH: app state \(app.state.rawValue) after this item; relaunched")
        XCTFail("CRASH (app not running in the foreground) at \(item)")
        let saved = prefix
        app.terminate()
        launchDemo(dark: false)
        continueAfterFailure = true
        prefix = saved
        waitForDemo()
        return false
    }

    // MARK: Panels and layers

    func openInspectorIfNeeded() {
        if isPad {
            if !element("inspector").exists { tap("inspector.toggle"); pause(0.8) }
        }
    }

    func openSidebarIfNeeded() {
        if isPad, !element("sidebar").exists { tap("sidebar.toggle"); pause(0.8) }
    }

    func closeOverlays() {
        if isPad {
            // Narrow iPad windows overlay the panels: close them so the canvas is reachable.
            if element("inspector").exists, element("inspector.toggle").exists, canvas.frame.width < 400 { tap("inspector.toggle") }
        } else if element("sheet.close").exists {
            tap("sheet.close"); pause(0.8)
        }
    }

    func selectFirstLayer() {
        if !isPad { tap("phone.layers"); pause(1) } else { openSidebarIfNeeded() }
        let q = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", "layer\\.[0-9]+"))
        _ = q.firstMatch.waitForExistence(timeout: 8)
        for e in q.allElementsBoundByIndex where canTap(e) { e.tap(); break }
        pause(0.8)
        if !isPad { tap("sheet.close"); pause(0.8) }
    }

    // MARK: Undo, alerts, strays

    func undoAll(max count: Int = 6) {
        for _ in 0..<count {
            let u = element("undo")
            guard u.exists, u.isEnabled, canTap(u) else { return }
            u.tap()
            pause(0.5)
        }
    }

    @discardableResult
    func dismissStrays() -> [String] {
        var alerts: [String] = []
        for _ in 0..<5 {
            if app.alerts.firstMatch.exists, let text = dismissAlert() { alerts.append(text); pause(0.5); continue }
            var acted = false
            for id in ["cmdSheet.cancel", "export.done", "palette.done", "templates.cancel", "sheet.close"] where element(id).exists {
                if let c = hit(id) { c.tap(); pause(0.8); acted = true; break }
            }
            if acted { continue }
            break
        }
        return alerts
    }

    /// If a parameter sheet is open: fill what is empty, Apply, record the engine's message, close it.
    func resolveSheet() -> (text: String, refused: String?) {
        let run = element("cmdSheet.run")
        guard run.waitForExistence(timeout: 2) else { return ("", nil) }
        var text = "sheet"
        if !run.isEnabled {
            for field in app.textFields.allElementsBoundByIndex where field.exists && field.isHittable {
                let value = (field.value as? String) ?? ""
                if value.isEmpty || value == field.placeholderValue {
                    field.tap(); field.typeText("Tour"); text += " filled-text"
                }
            }
            if app.keyboards.count > 0 { app.keyboards.buttons["return"].firstMatch.tap() }
            pause(0.4)
        }
        var refused: String?
        if run.exists && run.isEnabled && run.isHittable {
            run.tap()
            text += " applied"
            pause(1.2)
            let err = element("cmdSheet.error")
            if err.exists { refused = err.label; text += " ERROR" }
            let result = element("cmdSheet.result")
            if result.exists { text += " result=\(String(result.label.prefix(100)).replacingOccurrences(of: "\n", with: " "))" }
        } else if run.exists {
            text += " apply-disabled"
            refused = "Apply stays disabled with defaults"
        }
        if let c = hit("cmdSheet.cancel") { c.tap() }
        pause(0.6)
        return (text, refused)
    }

    // MARK: Palette

    func openPalette() -> Bool {
        dismissStrays()
        if let b = hit("palette.open") { b.tap() } else {
            guard let more = hit("menu.more") else { note("palette: no palette.open or menu.more"); return false }
            more.tap(); pause(0.6)
            guard let p = hit("menu.palette") else { note("palette: menu.palette missing"); app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap(); return false }
            p.tap()
        }
        return element("palette").waitForExistence(timeout: 8)
    }

    /// Runs one palette command by searching its id. "ran", "disabled: <text>", "off-screen" or "missing".
    func runPaletteCommand(_ id: String) -> String {
        if !openPalette() { dismissStrays(); if !openPalette() { return "palette-unreachable" } }
        let search = element("palette.search")
        if search.waitForExistence(timeout: 3) {
            search.tap()
            search.typeText(id)
            pause(0.6)
        }
        let q = app.buttons.matching(identifier: "command.\(id)")
        var row: XCUIElement?
        for e in q.allElementsBoundByIndex where canTap(e) { row = e; break }
        guard let row else {
            let exists = q.firstMatch.exists
            dismissStrays()
            return exists ? "off-screen" : "missing"
        }
        if !row.isEnabled {
            let label = row.label.replacingOccurrences(of: "\n", with: " ")
            dismissStrays()
            return "disabled: \(label)"
        }
        if app.keyboards.count > 0 { app.keyboards.buttons["Search"].firstMatch.tap() }
        row.tap()
        pause(1.5)
        return "ran"
    }
}
