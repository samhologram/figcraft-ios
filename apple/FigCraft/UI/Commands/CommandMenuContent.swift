import SwiftUI
@preconcurrency import FigCraftKit

/// Renders menu entries from the engine's menu layout (`MenuEntry`: command / separator / submenu) in the desktop's
/// order. Use inside a `Menu`, `contextMenu` or toolbar overflow.
struct CommandMenuContent: View {
    let model: EditorModel
    let entries: [MenuEntry]
    var pathID = "menu"

    private var visible: [MenuEntry] {
        var out: [MenuEntry] = []
        for e in entries {
            switch e.kind {
            case "command":
                if CommandCatalog.shared.isExcluded(e.id) { continue }
                out.append(e)
            case "separator":
                if out.isEmpty || out.last?.kind == "separator" { continue }
                out.append(e)
            default:
                if hasContent(e) { out.append(e) }
            }
        }
        while out.last?.kind == "separator" { out.removeLast() }
        return out
    }

    private func hasContent(_ entry: MenuEntry) -> Bool {
        entry.children.contains { child in
            switch child.kind {
            case "command": return !CommandCatalog.shared.isExcluded(child.id)
            case "separator": return false
            default: return hasContent(child)
            }
        }
    }

    var body: some View {
        let list = visible
        ForEach(Array(list.enumerated()), id: \.offset) { index, entry in
            switch entry.kind {
            case "command":
                CommandMenuButton(model: model, id: entry.id, label: entry.label)
            case "separator":
                Divider()
            default:
                Menu(entry.label) {
                    CommandMenuContent(model: model, entries: entry.children, pathID: "\(pathID).\(index)")
                }
                .accessibilityIdentifier("\(pathID).\(entry.label)")
            }
        }
    }
}

/// A menu item for one catalog command (`command.<id>`).
struct CommandMenuButton: View {
    let model: EditorModel
    let id: String
    var label: String?

    @Environment(EditorUIState.self) private var ui: EditorUIState?

    var body: some View {
        Button {
            // The version history panel is a sheet here (the engine only raises a UI request for it).
            if id == "file.versionHistory", let ui {
                ui.showVersions = true
            } else {
                model.present(id)
            }
        } label: {
            Text(verbatim: label ?? CommandCatalog.shared.label(id))
        }
        .disabled(!model.isEnabled(id))
        .accessibilityIdentifier("command.\(id)")
    }
}

/// The overflow menu ("…"): every desktop menu as a submenu, plus the command palette.
struct OverflowMenu: View {
    let model: EditorModel

    @Environment(EditorUIState.self) private var ui: EditorUIState?

    var body: some View {
        Menu {
            Button {
                model.showCommandPalette = true
            } label: {
                Label("Quick Actions", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("menu.palette")
            Button {
                ui?.showComments = true
            } label: {
                Label("Comments", systemImage: "bubble.left")
            }
            .accessibilityIdentifier("menu.comments")
            Button {
                ui?.showVersions = true
            } label: {
                Label("Version history", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityIdentifier("menu.versions")
            Divider()
            ForEach(CommandCatalog.shared.menus, id: \.title) { section in
                Menu(section.title) {
                    CommandMenuContent(model: model, entries: section.items, pathID: "menu.\(section.title)")
                }
                .accessibilityIdentifier("menu.\(section.title)")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("menu.more")
    }
}
