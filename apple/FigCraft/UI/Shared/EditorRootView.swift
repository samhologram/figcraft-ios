import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import FigCraftKit

private struct PendingCommand: Identifiable {
    let id: String
}

/// Entry view of an open document: picks the iPad or iPhone layout, publishes the model to the menu bar and hosts
/// every sheet, alert, importer, toast and the presenter.
struct EditorRootView: View {
    @Bindable var model: EditorModel

    @Environment(\.undoManager) private var undoManager
    @State private var ui = EditorUIState()
    @State private var commandItem: PendingCommand?
    @State private var paletteShown = false
    @State private var exportShown = false
    @State private var templatesShown = false
    @State private var commentsShown = false
    @State private var versionsShown = false
    @State private var renameText = ""

    init(model: EditorModel) {
        _model = Bindable(model)
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if geo.size.width < 700 {
                    PhoneEditorView(model: model)
                } else {
                    PadEditorView(model: model)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: model.panelRequest) { _, _ in
                guard geo.size.width < 700 else { return }
                ui.phoneSheet = model.lastRequestedPanel.isLeading ? .layers : .design
            }
        }
        .environment(ui)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.state.editingText { TextToolbar(model: model) }
        }
        .focusedSceneValue(\.editorModel, model)
        .overlay(alignment: .topLeading) {
            if model.isDemoReady {
                // Marker for UI tests: present once demo seeding finished.
                Color.clear
                    .frame(width: 2, height: 2)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("Demo ready")
                    .accessibilityIdentifier("demoReady")
            }
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Text(verbatim: toast)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("toast")
            }
        }
        .animation(.snappy(duration: 0.25), value: model.toast)
        .onAppear { if model.undoManager == nil { model.undoManager = undoManager } }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        // Sheets wait for an open iPhone panel sheet, so presentations never collide.
        .sheet(item: $commandItem, onDismiss: { model.pendingCommand = nil }) { item in
            CommandSheet(model: model, commandID: item.id)
        }
        .sheet(isPresented: $paletteShown, onDismiss: { model.showCommandPalette = false }) {
            CommandPaletteView(model: model)
        }
        .sheet(isPresented: $exportShown, onDismiss: { model.showExport = false }) {
            ExportSheet(model: model)
        }
        .sheet(isPresented: $templatesShown, onDismiss: { model.showTemplates = false }) {
            TemplatesSheet(model: model)
        }
        .sheet(isPresented: $commentsShown, onDismiss: { ui.showComments = false }) {
            CommentsSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $versionsShown, onDismiss: { ui.showVersions = false }) {
            VersionsSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: ui.showComments) { _, on in
            if on { presentAfterPanel { commentsShown = true } } else { commentsShown = false }
        }
        .onChange(of: ui.showVersions) { _, on in
            if on { presentAfterPanel { versionsShown = true } } else { versionsShown = false }
        }
        .onChange(of: model.pendingCommand, initial: true) { _, new in
            if let new { presentAfterPanel { commandItem = PendingCommand(id: new) } } else { commandItem = nil }
        }
        .onChange(of: model.showCommandPalette, initial: true) { _, on in
            if on { presentAfterPanel { paletteShown = true } } else { paletteShown = false }
        }
        .onChange(of: model.showExport, initial: true) { _, on in
            if on { presentAfterPanel { exportShown = true } } else { exportShown = false }
        }
        .onChange(of: model.showTemplates, initial: true) { _, on in
            if on { presentAfterPanel { templatesShown = true } } else { templatesShown = false }
        }
        .fileImporter(
            isPresented: $model.showImporter,
            allowedContentTypes: [.svg, .png, .jpeg, .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): model.importFiles(urls)
            case .failure(let error): model.lastError = error.localizedDescription
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { model.lastError = nil }
                .accessibilityIdentifier("error.ok")
        } message: {
            Text(verbatim: model.lastError ?? "")
        }
        .alert("Rename layer", isPresented: Binding(
            get: { model.renameLayerID != nil },
            set: { if !$0 { model.renameLayerID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { model.renameLayerID = nil }
            Button("Rename") {
                if let id = model.renameLayerID { model.run("object.rename", ["ids": [id], "name": renameText]) }
                model.renameLayerID = nil
            }
            .accessibilityIdentifier("rename.ok")
        }
        .onChange(of: model.renameLayerID) { _, id in
            if let id { renameText = model.layers.first { $0.id == id }?.name ?? "" }
        }
        .fullScreenCover(isPresented: $model.isPresenting) {
            if let presenter = model.presenter {
                PresentView(model: presenter) { model.isPresenting = false }
            } else {
                Color.black.ignoresSafeArea().onAppear { model.isPresenting = false }
            }
        }
    }

    /// On iPhone the panel sheet may be up; close it, wait for the dismissal, then present.
    private func presentAfterPanel(_ action: @escaping @MainActor () -> Void) {
        if ui.phoneSheet != nil {
            ui.phoneSheet = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                action()
            }
        } else {
            action()
        }
    }
}
