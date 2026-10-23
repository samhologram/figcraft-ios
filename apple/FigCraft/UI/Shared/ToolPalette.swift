import SwiftUI
@preconcurrency import FigCraftKit

/// One tool group of the iPad's floating bottom toolbar: a button for the group's current tool; tap = use it,
/// long press (or the menu) = the flyout with the group's other tools. Every tool button, in the flyout too,
/// carries `tool.<id>`.
struct ToolGroupButton: View {
    let model: EditorModel
    let group: ToolGroup

    @State private var remembered: String?

    private var shown: ToolInfo {
        if let active = group.tools.first(where: { $0.id == model.tool }) { return active }
        if let remembered, let tool = group.tools.first(where: { $0.id == remembered }) { return tool }
        return group.tools[0]
    }

    private var isActive: Bool { group.tools.contains { $0.id == model.tool } }

    var body: some View {
        if group.tools.isEmpty {
            EmptyView()
        } else if group.tools.count == 1 {
            Button { use(group.tools[0]) } label: { glyph(group.tools[0]) }
                .accessibilityIdentifier("tool.\(group.tools[0].id)")
                .accessibilityLabel(group.tools[0].label)
                .accessibilityAddTraits(isActive ? .isSelected : [])
        } else {
            let current = shown
            Menu {
                ForEach(group.tools, id: \.id) { tool in
                    Button { use(tool) } label: {
                        Label(tool.label + shortcutSuffix(tool), systemImage: Symbols.tool(tool.id))
                    }
                    .accessibilityIdentifier("tool.\(tool.id)")
                }
            } label: {
                glyph(current)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(3)
                    }
            } primaryAction: {
                use(current)
            }
            .accessibilityIdentifier("tool.\(current.id)")
            .accessibilityLabel(current.label)
            .accessibilityHint("Long press for more \(group.name.lowercased())")
            .accessibilityAddTraits(isActive ? .isSelected : [])
        }
    }

    private func shortcutSuffix(_ tool: ToolInfo) -> String {
        guard let s = tool.shortcut, !s.isEmpty else { return "" }
        return "  \(CommandCatalog.display(s))"
    }

    private func use(_ tool: ToolInfo) {
        remembered = tool.id
        model.run(tool.command)
    }

    private func glyph(_ tool: ToolInfo) -> some View {
        let active = isActive && (group.tools.count == 1 || tool.id == model.tool)
        return Image(systemName: Symbols.tool(tool.id))
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(active ? Color.white : Color.primary)
            .frame(width: 44, height: 40)
            .background {
                if active { Capsule().fill(Color.accentColor) }
            }
            .contentShape(Capsule())
    }
}

/// The iPad's floating toolbar pill.
struct FloatingToolbar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CommandCatalog.shared.toolGroups, id: \.key) { group in
                ToolGroupButton(model: model, group: group)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbar")
    }
}

/// The iPhone's bottom tool strip: every tool in one horizontal scroller (the last resort of the degradation order).
struct ToolStrip: View {
    let model: EditorModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(CommandCatalog.shared.toolGroups, id: \.key) { group in
                    ForEach(group.tools, id: \.id) { tool in
                        let active = model.tool == tool.id
                        Button { model.run(tool.command) } label: {
                            Image(systemName: Symbols.tool(tool.id))
                                .font(.system(size: 18))
                                .foregroundStyle(active ? Color.white : Color.primary)
                                .frame(width: 44, height: 40)
                                .background { if active { Capsule().fill(Color.accentColor) } }
                                .contentShape(Capsule())
                        }
                        .accessibilityIdentifier("tool.\(tool.id)")
                        .accessibilityLabel(tool.label)
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .glassEffect(.regular, in: Capsule())
        .accessibilityIdentifier("toolstrip")
    }
}

/// Zero-size invisible buttons that give a hardware keyboard the desktop's single-key tool shortcuts. `opacity(0)`
/// rather than `hidden()`: a hidden button does not receive its key equivalent. A focused text field gets bare keys first.
struct ToolShortcutButtons: View {
    let model: EditorModel

    private struct Item: Identifiable {
        let id: String
        let label: String
        let command: String
        let shortcut: KeyboardShortcut
    }

    @MainActor private static let items: [Item] = {
        var out: [Item] = []
        var seen = Set<String>()
        for group in CommandCatalog.shared.toolGroups {
            for tool in group.tools {
                guard let text = tool.shortcut, !text.isEmpty,
                      let parsed = CommandCatalog.parseShortcut(text),
                      parsed.modifiers.isEmpty || parsed.modifiers == .shift,
                      seen.insert(tool.id).inserted else { continue }
                out.append(Item(id: tool.id, label: tool.label, command: tool.command, shortcut: parsed))
            }
        }
        return out
    }()

    var body: some View {
        Group {
            ForEach(Self.items) { item in
                Button(item.label) { model.run(item.command) }
                    .keyboardShortcut(item.shortcut)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
