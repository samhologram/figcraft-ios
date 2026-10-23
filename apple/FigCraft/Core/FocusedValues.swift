import SwiftUI

private struct EditorModelKey: FocusedValueKey {
    typealias Value = EditorModel
}

extension FocusedValues {
    /// The model of the focused document scene; read by the menu bar (`FigCraftCommands`).
    var editorModel: EditorModel? {
        get { self[EditorModelKey.self] }
        set { self[EditorModelKey.self] = newValue }
    }
}
