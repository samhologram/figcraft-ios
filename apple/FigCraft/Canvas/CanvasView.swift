import SwiftUI
@preconcurrency import FigCraftKit

/// The design canvas: renders the engine viewport, draws the selection overlay and turns touch, Pencil, trackpad
/// and keyboard input into engine events. One `UIViewRepresentable` owns the gesture recognizers because SwiftUI
/// gestures cannot separate one-finger from two-finger input.
struct CanvasView: View {
    let model: EditorModel

    var body: some View {
        CanvasRepresentable(model: model)
            .accessibilityIdentifier("canvas")
    }
}

private struct CanvasRepresentable: UIViewRepresentable {
    let model: EditorModel

    func makeUIView(context: Context) -> CanvasHostView {
        CanvasHostView(model: model)
    }

    func updateUIView(_ view: CanvasHostView, context: Context) {
        // Reading these registers observation: the view updates when any of them changes.
        let revision = model.canvasRevision
        let overlay = model.overlay
        let editing = model.state.editingText
        let tool = model.tool
        view.apply(revision: revision, overlay: overlay, editingText: editing, tool: tool)
    }
}
