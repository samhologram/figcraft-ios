import Foundation
@preconcurrency import FigCraftKit

/// Undo integration. The engine owns the real history; the scene `UndoManager` mirrors it: every history step
/// registers one entry whose handler steps the engine, and registers the symmetric redo inside it. That makes
/// the three-finger swipe, Cmd-Z, shake to undo and the document's dirty state (autosave) work.
extension EditorModel {
    func undo() {
        guard state.canUndo else { return }
        if let manager = undoManager, manager.canUndo {
            manager.undo()  // its handler performs the engine step
        } else {
            stepEngine(undo: true)
        }
    }

    func redo() {
        guard state.canRedo else { return }
        if let manager = undoManager, manager.canRedo {
            manager.redo()
        } else {
            stepEngine(undo: false)
        }
    }

    /// Registers one undo entry for the history step the engine just recorded.
    func registerUndoStep(label: String?) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.managerRequestedUndo() }
        }
        if let label, !label.isEmpty, !manager.isUndoing, !manager.isRedoing { manager.setActionName(label) }
    }

    private func managerRequestedUndo() {
        stepEngine(undo: true)
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.managerRequestedRedo() }
        }
        if let label = state.redoLabel, !label.isEmpty { manager.setActionName(label) }
    }

    private func managerRequestedRedo() {
        stepEngine(undo: false)
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.managerRequestedUndo() }
        }
        if let label = state.undoLabel, !label.isEmpty { manager.setActionName(label) }
    }

    private func stepEngine(undo: Bool) {
        suppressUndoRegistration = true
        defer { suppressUndoRegistration = false }
        do {
            _ = try (undo ? handle.undo() : handle.redo())
        } catch {
            report(error)
        }
        refresh()
        handleUIRequests()
    }
}
