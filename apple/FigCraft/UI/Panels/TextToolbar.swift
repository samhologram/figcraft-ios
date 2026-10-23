import SwiftUI
@preconcurrency import FigCraftKit

/// A compact formatting bar shown above the keyboard while text is being edited (`model.state.editingText`):
/// bold, italic, underline, strikethrough, alignment, lists and Done. Every button runs an engine `text.*` command
/// (while editing they apply to the selected characters). Buttons are `command.<id>`.
struct TextToolbar: View {
    let model: EditorModel

    private struct Item: Identifiable {
        let command: String
        let symbol: String
        let label: String
        var id: String { command }
    }

    private static let styles: [Item] = [
        Item(command: "text.bold", symbol: "bold", label: "Bold"),
        Item(command: "text.italic", symbol: "italic", label: "Italic"),
        Item(command: "text.underline", symbol: "underline", label: "Underline"),
        Item(command: "text.strikethrough", symbol: "strikethrough", label: "Strikethrough"),
    ]
    private static let aligns: [Item] = [
        Item(command: "text.alignLeft", symbol: "text.alignleft", label: "Align left"),
        Item(command: "text.alignCenter", symbol: "text.aligncenter", label: "Align center"),
        Item(command: "text.alignRight", symbol: "text.alignright", label: "Align right"),
        Item(command: "text.alignJustify", symbol: "text.justify", label: "Justify"),
    ]
    private static let lists: [Item] = [
        Item(command: "text.bulletList", symbol: "list.bullet", label: "Bulleted list"),
        Item(command: "text.numberList", symbol: "list.number", label: "Numbered list"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    group(Self.styles)
                    divider
                    group(Self.aligns)
                    divider
                    group(Self.lists)
                }
                .padding(.horizontal, 6)
            }
            Button {
                model.run("text.edit.end")
            } label: {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityIdentifier("command.text.edit.end")
        }
        .frame(height: 44)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("textToolbar")
    }

    private var divider: some View {
        Divider().frame(height: 22).padding(.horizontal, 4)
    }

    private func group(_ items: [Item]) -> some View {
        ForEach(items) { item in
            Button {
                model.run(item.command)
            } label: {
                Image(systemName: item.symbol)
                    .font(.system(size: 16))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.label)
            .accessibilityIdentifier("command.\(item.command)")
        }
    }
}
