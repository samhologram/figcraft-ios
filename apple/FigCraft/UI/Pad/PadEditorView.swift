import SwiftUI
@preconcurrency import FigCraftKit

/// iPad layout: Layers / Pages / Assets sidebar on the leading edge, the canvas, the Design / Prototype / Inspect
/// inspector on the trailing edge and a floating tool toolbar. Below 1000 pt the sidebar and inspector become
/// overlays (one at a time) so the canvas keeps its width.
struct PadEditorView: View {
    @Bindable var model: EditorModel

    @Environment(EditorUIState.self) private var ui
    @State private var wide = true

    private let sidebarWidth: CGFloat = 280
    private let inspectorWidth: CGFloat = 320

    var body: some View {
        GeometryReader { geo in
            let isWide = geo.size.width >= 1000
            HStack(spacing: 0) {
                if isWide && model.sidebarVisible {
                    PanelDockView(model: model, leading: true).frame(width: sidebarWidth)
                    Divider()
                }
                canvas
                if isWide && model.inspectorVisible {
                    Divider()
                    PanelDockView(model: model, leading: false).frame(width: inspectorWidth)
                }
            }
            .overlay(alignment: .leading) {
                if !isWide && model.sidebarVisible {
                    PanelDockView(model: model, leading: true)
                        .frame(width: min(sidebarWidth, geo.size.width * 0.6))
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
                        .padding(8)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .overlay(alignment: .trailing) {
                if !isWide && model.inspectorVisible {
                    PanelDockView(model: model, leading: false)
                        .frame(width: min(inspectorWidth, geo.size.width * 0.6))
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
                        .padding(8)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: model.sidebarVisible)
            .animation(.snappy(duration: 0.25), value: model.inspectorVisible)
            .onChange(of: model.panelRequest) { _, _ in
                guard !isWide else { return }
                if model.lastRequestedPanel.isLeading { model.inspectorVisible = false }
                else { model.sidebarVisible = false }
            }
            .onChange(of: isWide, initial: true) { old, new in
                wide = new
                // Entering the narrow layout starts with the canvas alone; opening a panel then overlays it.
                if !new && (old || ui.padOverlayWide) {
                    model.sidebarVisible = false
                    model.inspectorVisible = false
                }
                ui.padOverlayWide = new
            }
        }
        .background { ToolShortcutButtons(model: model) }
        .toolbar { toolbar }
    }

    private var canvas: some View {
        ZStack(alignment: .bottom) {
            CanvasView(model: model)
            FloatingToolbar(model: model)
                .padding(.bottom, 14)
        }
        .clipped()
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
                toggleSidebar()
            } label: {
                Label("Layers", systemImage: "sidebar.leading")
            }
            .accessibilityIdentifier("sidebar.toggle")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.state.canUndo)
                .accessibilityIdentifier("undo")
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.state.canRedo)
                .accessibilityIdentifier("redo")
            Button { model.present("proto.present") } label: { Label("Play", systemImage: "play.fill") }
                .accessibilityIdentifier("command.proto.present")
            Button { ui.showComments = true } label: { Label("Comments", systemImage: "bubble.left") }
                .accessibilityIdentifier("comments.open")
            Button { model.showExport = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("share")
            Button { model.showCommandPalette = true } label: { Label("Quick Actions", systemImage: "magnifyingglass") }
                .accessibilityIdentifier("palette.open")
            OverflowMenu(model: model)
            Button {
                toggleInspector()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .accessibilityIdentifier("inspector.toggle")
        }
    }

    private func toggleSidebar() {
        let opening = !model.sidebarVisible
        model.sidebarVisible = opening
        if opening && !wide { model.inspectorVisible = false }
    }

    private func toggleInspector() {
        let opening = !model.inspectorVisible
        model.inspectorVisible = opening
        if opening && !wide { model.sidebarVisible = false }
    }
}
