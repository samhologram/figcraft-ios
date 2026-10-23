import CoreGraphics
@preconcurrency import FigCraftKit

/// Canvas input and view control. View points are the SwiftUI points of the canvas view.
extension EditorModel {
    /// The canvas changed size: tell the engine (the first call on a fresh document zooms to fit).
    func setViewport(_ size: CGSize) {
        guard size.width >= 1, size.height >= 1 else { return }
        handle.setViewport(width: Double(size.width), height: Double(size.height))
        refresh()
        canvasRevision += 1
    }

    /// Pointer event ("down", "move", "up", "hover", "double") with modifiers and optional Pencil pressure.
    func pointer(_ kind: String, at point: CGPoint, pressure: Double? = nil,
                 shift: Bool = false, alt: Bool = false, cmd: Bool = false, ctrl: Bool = false) {
        guard point.x.isFinite, point.y.isFinite else { return }
        do {
            try handle.pointer(kind: kind, x: Double(point.x), y: Double(point.y),
                               shift: shift, alt: alt, cmd: cmd, ctrl: ctrl, pressure: pressure)
        } catch {
            if kind != "hover" && kind != "move" { report(error) }
        }
        let light = kind == "move" || kind == "hover"
        refresh(full: !light)
        if !light { handleUIRequests() }
    }

    func panView(dx: CGFloat, dy: CGFloat) {
        guard dx.isFinite, dy.isFinite else { return }
        handle.pan(dx: Double(dx), dy: Double(dy))
        refresh(full: false)
        canvasRevision += 1
    }

    func zoomView(to zoom: Double, at point: CGPoint) {
        guard zoom.isFinite, zoom > 0, point.x.isFinite, point.y.isFinite else { return }
        handle.zoomAt(zoom: zoom, x: Double(point.x), y: Double(point.y))
        refresh(full: false)
        canvasRevision += 1
    }

    func fitView() { run("view.zoomFit") }

    /// A key while editing text (or a tool key). True when the engine handled it.
    @discardableResult
    func key(_ name: String, shift: Bool = false, alt: Bool = false, cmd: Bool = false) -> Bool {
        var handled = false
        do { handled = try handle.key(name: name, shift: shift, alt: alt, cmd: cmd) } catch { report(error) }
        refresh()
        handleUIRequests()
        return handled
    }

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        if text == "\n" {
            key("Enter")
            return
        }
        do { try handle.insertText(text: text) } catch { report(error) }
        refresh()
    }
}
