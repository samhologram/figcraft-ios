import SwiftUI
@preconcurrency import FigCraftKit

/// iPhone layout: the canvas fills the screen, a bottom tool strip, and buttons that open Layers, Design and
/// Prototype as sheets with medium / large detents (the canvas stays interactive above the medium detent).
struct PhoneEditorView: View {
    @Bindable var model: EditorModel

    @Environment(EditorUIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        CanvasView(model: model)
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 6) {
                    ToolStrip(model: model)
                    actionRow
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
            .background { ToolShortcutButtons(model: model) }
            .toolbar {
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
                }
            }
            .sheet(item: $ui.phoneSheet) { sheet in
                PhonePanelSheet(model: model, sheet: sheet) { ui.phoneSheet = nil }
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
            }
    }

    private var actionRow: some View {
        HStack(spacing: 4) {
            sheetButton(.layers, "Layers", "square.stack.3d.up")
            sheetButton(.design, "Design", "slider.horizontal.3")
            sheetButton(.prototype, "Prototype", "arrow.triangle.branch")
            Button { model.showCommandPalette = true } label: {
                Image(systemName: "magnifyingglass").frame(width: 44, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("Quick Actions")
            .accessibilityIdentifier("palette.open")
            OverflowMenu(model: model)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 40)
        }
        .padding(.horizontal, 6)
        .glassEffect(.regular, in: Capsule())
    }

    private func sheetButton(_ sheet: PhoneSheet, _ title: String, _ symbol: String) -> some View {
        Button {
            ui.phoneSheet = ui.phoneSheet == sheet ? nil : sheet
        } label: {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(verbatim: title).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("phone.\(sheet.rawValue)")
    }
}

/// The content of an iPhone panel sheet: the same panel views as the iPad columns, with their tabs.
struct PhonePanelSheet: View {
    @Bindable var model: EditorModel
    let sheet: PhoneSheet
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                switch sheet {
                case .layers:
                    PanelTabs(selection: $model.leftPanel)
                case .design, .prototype:
                    PanelTabs(selection: $model.rightPanel)
                }
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("sheet.close")
            }
            .padding(.horizontal, 12)
            .padding(.top, 18)
            .padding(.bottom, 8)
            Group {
                switch sheet {
                case .layers:
                    if model.leftPanel == .layers { LayersPanel(model: model) } else { AssetsPanel(model: model) }
                case .design, .prototype:
                    switch model.rightPanel {
                    case .design: DesignInspector(model: model)
                    case .prototype: PrototypeInspector(model: model)
                    case .inspect: InspectInspector(model: model)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear {
            if sheet == .prototype { model.rightPanel = .prototype }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phone.sheet.\(sheet.rawValue)")
    }
}
