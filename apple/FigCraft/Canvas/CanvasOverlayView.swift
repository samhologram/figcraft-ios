import UIKit
@preconcurrency import FigCraftKit

/// Draws the engine's `Overlay` (view points) over the render in the accent colour.
final class CanvasOverlayView: UIView {
    var overlay: Overlay? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { nil }

    private func cg(_ r: Rect) -> CGRect? {
        guard r.x.isFinite, r.y.isFinite, r.width.isFinite, r.height.isFinite else { return nil }
        return CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    override func draw(_ rect: CGRect) {
        guard let overlay, let ctx = UIGraphicsGetCurrentContext() else { return }
        let accent = tintColor ?? .systemBlue
        ctx.setStrokeColor(accent.cgColor)
        ctx.setFillColor(accent.cgColor)

        // Hover first, under the selection.
        if let hover = overlay.hover.flatMap(cg) {
            ctx.setLineWidth(1)
            ctx.setStrokeColor(accent.withAlphaComponent(0.8).cgColor)
            ctx.stroke(hover)
        }
        ctx.setStrokeColor(accent.cgColor)

        ctx.setLineWidth(1)
        for item in overlay.selection {
            if let r = cg(item) { ctx.stroke(r) }
        }

        if let bounds = overlay.bounds.flatMap(cg) {
            ctx.setLineWidth(1.5)
            ctx.stroke(bounds)
            drawHandles(ctx, bounds: bounds, accent: accent)
        }

        if let marquee = overlay.marquee.flatMap(cg) {
            ctx.setFillColor(accent.withAlphaComponent(0.1).cgColor)
            ctx.fill(marquee)
            ctx.setLineWidth(1)
            ctx.stroke(marquee)
        }

        ctx.setFillColor(accent.cgColor)
        for guide in overlay.guides {
            if let r = cg(guide) { ctx.fill(CGRect(x: r.minX, y: r.minY, width: max(r.width, 1), height: max(r.height, 1))) }
        }

        if let caret = overlay.caret.flatMap(cg) {
            ctx.fill(CGRect(x: caret.minX, y: caret.minY, width: max(caret.width, 2), height: caret.height))
        }
    }

    /// Eight resize handles (corners and edge midpoints): white squares with an accent border.
    private func drawHandles(_ ctx: CGContext, bounds: CGRect, accent: UIColor) {
        let side: CGFloat = 8
        let xs = [bounds.minX, bounds.midX, bounds.maxX]
        let ys = [bounds.minY, bounds.midY, bounds.maxY]
        ctx.setLineWidth(1)
        for (ix, x) in xs.enumerated() {
            for (iy, y) in ys.enumerated() where !(ix == 1 && iy == 1) {
                let handle = CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fill(handle)
                ctx.setStrokeColor(accent.cgColor)
                ctx.stroke(handle)
            }
        }
    }
}
