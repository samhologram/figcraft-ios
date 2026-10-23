import XCTest

/// Runs every menu command through the command palette: search its id, tap the row, resolve the parameter sheet or
/// alert, record the outcome, restore state with undo. The id list is read from the palette itself.
@MainActor
final class CommandTourUITests: TourTestCase {
    private struct Row { let id: String; let enabled: Bool; let label: String }

    func testCommandsPortrait() throws { try tour(landscape: false) }
    func testCommandsLandscape() throws { try tour(landscape: true) }

    private func enumeratePalette() -> [Row] {
        guard openPalette() else { note("enumerate: palette could not be opened"); return [] }
        let list = element("palette.list")
        var rows: [Row] = []
        var seen = Set<String>()
        var stagnant = 0
        for _ in 0..<200 {
            var fresh = 0
            for b in list.buttons.allElementsBoundByIndex where b.exists {
                let ident = b.identifier
                guard ident.hasPrefix("command."), seen.insert(ident).inserted else { continue }
                rows.append(Row(id: String(ident.dropFirst("command.".count)), enabled: b.isEnabled, label: b.label.replacingOccurrences(of: "\n", with: " ")))
                fresh += 1
            }
            stagnant = fresh == 0 ? stagnant + 1 : 0
            if stagnant >= 2 { break }
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        dismissStrays()
        attach("palette-ids", rows.map { "\($0.id)\t\($0.enabled ? "enabled" : "DISABLED")\t\($0.label)" }.joined(separator: "\n"))
        return rows
    }

    private func tour(landscape: Bool) throws {
        startTour(name: "commands", landscape: landscape)
        defer { attachSummary(); flushNotes() }
        selectFirstLayer()
        var rows = enumeratePalette()
        if rows.isEmpty { XCTFail("the command palette listed no commands"); return }
        if let only { rows = rows.filter { only.contains($0.id) } }
        if let limit { rows = Array(rows.prefix(limit)) }
        var deferred: [Row] = []
        for row in rows where !run(row, final: false) { deferred.append(row) }
        for row in deferred { _ = run(row, final: true) }
    }

    /// False when the row was disabled and may be retried at the end.
    private func run(_ row: Row, final: Bool) -> Bool {
        let id = row.id
        let status = runPaletteCommand(id)
        var outcome = "reached"
        var detail = ""
        if status == "ran" {
            var parts: [String] = []
            let sheet = resolveSheet()
            if !sheet.text.isEmpty { parts.append(sheet.text); outcome = "acted" }
            var messages: [String] = []
            if let r = sheet.refused { messages.append(r) }
            messages += dismissStrays()
            if !messages.isEmpty {
                outcome = "refused"
                parts.append("MESSAGE=" + messages.joined(separator: " || "))
                note("\(id): \(messages.joined(separator: " || "))")
            }
            detail = parts.joined(separator: "; ")
        } else if status.hasPrefix("disabled") {
            if !final { return false }
            outcome = "not-reached"; detail = status
        } else {
            outcome = "not-reached"; detail = status
        }
        if !alive(id) { return true }
        record(id, outcome, detail)
        dismissStrays()
        // Preview, presentation and importers can leave a full-screen cover or the document picker up.
        if element("present.close").exists { tap("present.close"); pause(0.8) }
        undoAll(max: 3)
        return true
    }
}
