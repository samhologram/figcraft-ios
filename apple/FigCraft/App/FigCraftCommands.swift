import SwiftUI
@preconcurrency import FigCraftKit

// iPadOS menu bar generated from the engine's menu layout (`menuLayout()`): File, Edit, View extend the system
// menus; Object, Text, Arrange, Vector, Plugins, Preferences, Libraries and Tools are custom menus; Help extends
// the system one. Every item acts on the focused scene's model and carries `command.<id>` as identifier.
// A CommandsBuilder takes at most 10 items and ForEach is not Commands, so each menu is a `CommandMenu` /
// `CommandGroup` with the `ForEach` inside its content.

// MARK: - Layout

/// One entry of a generated menu.
struct MenuItem: Identifiable {
    enum Kind {
        case command(String)
        case separator
        case submenu(String, [String])
    }

    let id: Int
    let kind: Kind
}

@MainActor
enum MenuLayoutBuilder {
    /// Handled by the system menus, the document scene or the app shell.
    private static let hidden: Set<String> = [
        "file.new", "file.open", "file.save", "file.close", "window.new",
        "edit.undo", "edit.redo",
    ]
    /// Combinations the system or the document scene already owns.
    private static let reserved: Set<String> = ["cmd+n", "cmd+o", "cmd+w", "cmd+q", "cmd+h", "cmd+m", "cmd+p", "cmd+s",
                                                 "cmd+c", "cmd+x", "cmd+v", "cmd+z", "cmd+shift+z", "cmd+,", "cmd+a"]

    static func isVisible(_ id: String) -> Bool {
        let catalog = CommandCatalog.shared
        return catalog.isKnown(id) && !catalog.isExcluded(id) && !hidden.contains(id)
    }

    /// Entries of the top-level menu `title`, in layout order.
    static func entries(for title: String) -> [MenuItem] {
        guard let section = CommandCatalog.shared.menus.first(where: { $0.title == title }) else { return [] }
        var items: [MenuItem.Kind] = []
        for entry in section.items {
            switch entry.kind {
            case "separator":
                items.append(.separator)
            case "submenu":
                let ids = flatten(entry.children)
                if !ids.isEmpty { items.append(.submenu(entry.label, ids)) }
            default:
                if isVisible(entry.id) { items.append(.command(entry.id)) }
            }
        }
        return tidy(items).enumerated().map { MenuItem(id: $0.offset, kind: $0.element) }
    }

    private static func flatten(_ entries: [MenuEntry]) -> [String] {
        var ids: [String] = []
        for entry in entries {
            if entry.kind == "submenu" {
                ids.append(contentsOf: flatten(entry.children))
            } else if entry.kind == "command", isVisible(entry.id) {
                ids.append(entry.id)
            }
        }
        return ids
    }

    private static func tidy(_ items: [MenuItem.Kind]) -> [MenuItem.Kind] {
        var out: [MenuItem.Kind] = []
        for item in items {
            if case .separator = item {
                if out.isEmpty { continue }
                if case .separator = out[out.count - 1] { continue }
            }
            out.append(item)
        }
        while let tail = out.last, case .separator = tail { out.removeLast() }
        return out
    }

    /// Menu shortcuts by command id: the first command to ask for a combination wins. Unmodified (and Shift-only)
    /// keys stay out of menus so typing is never intercepted; the tool keys are hidden buttons in the editor.
    static let shortcuts: [String: KeyboardShortcut] = {
        var out: [String: KeyboardShortcut] = [:]
        var taken = reserved
        let catalog = CommandCatalog.shared
        for section in catalog.menus {
            for id in allIDs(section.items) where out[id] == nil && isVisible(id) {
                guard let shortcut = catalog.shortcut(id) else { continue }
                var mods = shortcut.modifiers
                mods.remove(.shift)
                if mods.isEmpty { continue }
                let key = signature(shortcut)
                if taken.contains(key) { continue }
                taken.insert(key)
                out[id] = shortcut
            }
        }
        return out
    }()

    private static func allIDs(_ entries: [MenuEntry]) -> [String] {
        entries.flatMap { $0.kind == "command" ? [$0.id] : allIDs($0.children) }
    }

    private static func signature(_ shortcut: KeyboardShortcut) -> String {
        var name = ""
        if shortcut.modifiers.contains(.command) { name += "cmd+" }
        if shortcut.modifiers.contains(.control) { name += "ctrl+" }
        if shortcut.modifiers.contains(.option) { name += "alt+" }
        if shortcut.modifiers.contains(.shift) { name += "shift+" }
        return name + String(shortcut.key.character)
    }
}

// MARK: - Views

/// One command in a menu.
private struct CommandButton: View {
    let id: String
    let model: EditorModel?

    var body: some View {
        Button(CommandCatalog.shared.label(id)) {
            if let panel = Self.panel(for: id) { model?.showPanel(panel) }
            else { model?.present(id) }
        }
            .keyboardShortcut(MenuLayoutBuilder.shortcuts[id])
            .disabled(!(model?.isEnabled(id) ?? false))
            .accessibilityIdentifier("command.\(id)")
    }

    static func panel(for id: String) -> DockPanelID? {
        switch id {
        case "view.layers": .layers
        case "view.assets": .assets
        case "view.design": .design
        case "view.prototype": .prototype
        default: nil
        }
    }
}

private struct WindowPanelMenu: Commands {
    var body: some Commands {
        CommandMenu("Window") {
            WindowPanelItems()
        }
    }
}

private struct WindowPanelItems: View {
    @FocusedValue(\.editorModel) private var model

    var body: some View {
        ForEach(DockPanelID.allCases) { panel in
            Button("Show \(panel.title)") { model?.showPanel(panel) }
                .disabled(model == nil)
                .accessibilityIdentifier("window.panel.\(panel.rawValue)")
        }
    }
}

/// The content of one generated menu. Submenus are one level deep (deeper levels are flattened by the layout).
private struct MenuContent: View {
    let title: String
    @FocusedValue(\.editorModel) private var model

    var body: some View {
        ForEach(MenuLayoutBuilder.entries(for: title)) { item in
            switch item.kind {
            case .command(let id):
                CommandButton(id: id, model: model)
            case .separator:
                Divider()
            case .submenu(let name, let ids):
                Menu(name) {
                    ForEach(ids, id: \.self) { id in CommandButton(id: id, model: model) }
                }
            }
        }
    }
}

/// A custom top-level menu.
private struct SectionMenu: Commands {
    let title: String

    var body: some Commands {
        CommandMenu(title) { MenuContent(title: title) }
    }
}

/// Menus that extend the system File, Edit, View and Help menus.
private struct SystemMenus: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) { MenuContent(title: "File") }
        CommandGroup(after: .pasteboard) { MenuContent(title: "Edit") }
        CommandGroup(after: .toolbar) { MenuContent(title: "View") }
        CommandGroup(after: .help) { MenuContent(title: "Help") }
    }
}

/// Object, Text, Arrange, Vector, Plugins, Preferences, Libraries, then Tools.
private struct CustomMenus: Commands {
    var body: some Commands {
        SectionMenu(title: "Object")
        SectionMenu(title: "Text")
        SectionMenu(title: "Arrange")
        SectionMenu(title: "Vector")
        SectionMenu(title: "Plugins")
        SectionMenu(title: "Preferences")
        SectionMenu(title: "Libraries")
        SectionMenu(title: "Tools")
    }
}

struct FigCraftCommands: Commands {
    var body: some Commands {
        SystemMenus()
        CustomMenus()
        WindowPanelMenu()
    }
}
