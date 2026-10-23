import SwiftUI
@preconcurrency import FigCraftKit

/// "Selection colors" (desktop `selection_colors.rs`): the distinct fill and stroke colours of the selection
/// (descendants and text ranges included), each editable for all the layers that use it. Shown when the selection
/// has two or more colours. Engine commands: `selection.colors` (query), `selection.setPaint`,
/// `selection.applyColorStyle`, `selection.selectColor`. Identifier `section.selectionColors`.
struct SelectionColorsSection: View {
    let model: EditorModel

    private struct ColorGroup: Identifiable {
        let id: Int
        let paint: JSONObject
        let targets: [Any]
        let style: String?
        let variable: String?
        var isSolid: Bool { (paint.string("type") ?? "solid") == "solid" }
        var hex: String { EngineColor.hex(paint["color"]) ?? "#000000" }
        var opacity: Double { paint.number("opacity") ?? 1 }
    }

    private struct StyleChoice: Identifiable {
        let id: String
        let name: String
    }

    @State private var groups: [ColorGroup] = []
    @State private var linkedNames: [String: String] = [:]
    @State private var colorStyles: [StyleChoice] = []
    @State private var pending: Task<Void, Never>?

    var body: some View {
        Group {
            if groups.count >= 2 {
                VStack(spacing: 0) {
                    Divider()
                    InspectorSection("selectionColors", title: "Selection colors") {
                        VStack(spacing: 8) {
                            ForEach(groups) { group in row(group) }
                        }
                    }
                }
            }
        }
        .onChange(of: model.state.revision, initial: true) { _, _ in schedule() }
        .onChange(of: model.state.selection) { _, _ in schedule() }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ group: ColorGroup) -> some View {
        let linked = group.style.flatMap { linkedNames[$0] } ?? group.variable.flatMap { linkedNames[$0] }
        HStack(spacing: 6) {
            if group.isSolid {
                PaintSwatch(hex: group.hex) { picked in send(group, hex: picked) }
                    .frame(width: 34)
                if let linked {
                    Text(verbatim: linked)
                        .font(.callout)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    CommitTextField(key: "selectionColor.\(group.id)", placeholder: "#RRGGBB", value: group.hex.uppercased()) { text in
                        guard let parsed = EngineColor.parse(text) else {
                            model.showToast("Invalid color")
                            return
                        }
                        send(group, hex: parsed.hex, opacity: parsed.alpha)
                    }
                }
            } else {
                Image(systemName: "circle.lefthalf.filled")
                    .frame(width: 34, height: 32)
                    .foregroundStyle(.secondary)
                Text(verbatim: linked ?? "Gradient")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("control.selectionColor.\(group.id)")
            }
            ScrubField(model: model, key: "selectionColor.\(group.id).opacity", label: "%", value: group.opacity,
                       scale: 100, step: 0.5, range: 0...100, decimals: 0) { v in
                send(group, opacity: v)
            }
            .frame(width: 84)
            menu(group)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selectionColor.\(group.id)")
    }

    private func menu(_ group: ColorGroup) -> some View {
        Menu {
            Button {
                model.run("selection.selectColor", ["targets": group.targets])
            } label: {
                Label("Select layers with this color", systemImage: "scope")
            }
            .accessibilityIdentifier("selectionColor.\(group.id).select")
            Menu("Color styles") {
                if colorStyles.isEmpty {
                    Text("No color styles")
                }
                ForEach(colorStyles) { style in
                    Button(style.name) {
                        model.run("selection.applyColorStyle", ["targets": group.targets, "style": style.id])
                    }
                }
            }
            .accessibilityIdentifier("selectionColor.\(group.id).styles")
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Color actions")
        .accessibilityIdentifier("selectionColor.\(group.id).menu")
    }

    // MARK: Engine

    /// `selection.setPaint`: the group's own paint with the new colour and/or opacity, for every slot of the group.
    private func send(_ group: ColorGroup, hex: String? = nil, opacity: Double? = nil) {
        var paint = group.paint
        if group.isSolid { paint["color"] = hex ?? group.hex }
        if let opacity, opacity.isFinite { paint["opacity"] = max(0, min(1, opacity)) }
        model.run("selection.setPaint", ["targets": group.targets, "paint": paint])
    }

    /// Re-reads the colours shortly after the document changes (a drag changes it every frame).
    private func schedule() {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if !Task.isCancelled { reload() }
        }
    }

    private func reload() {
        guard !model.state.selection.isEmpty,
              let result = model.query("selection.colors") as? JSONObject else {
            groups = []
            return
        }
        let list = result.objects("colors")
        let built: [ColorGroup] = list.enumerated().map { index, item in
            ColorGroup(id: index, paint: item.object("paint") ?? [:], targets: item["targets"] as? [Any] ?? [],
                       style: item.string("style"), variable: item.string("variable"))
        }
        groups = built
        guard built.count >= 2 else { return }
        var names: [String: String] = [:]
        let styles = (model.query("style.list") as? [Any])?.compactMap { $0 as? JSONObject } ?? []
        for style in styles {
            if let id = style.string("id"), let name = style.string("name") { names[id] = name }
        }
        colorStyles = styles.compactMap { style -> StyleChoice? in
            guard style.string("type") == "paint", let id = style.string("id"), let name = style.string("name") else { return nil }
            return StyleChoice(id: id, name: name)
        }
        if built.contains(where: { $0.variable != nil }),
           let variables = (model.query("variable.list") as? JSONObject)?.objects("variables") {
            for variable in variables {
                if let id = variable.string("id"), let name = variable.string("name") { names[id] = name }
            }
        }
        linkedNames = names
    }
}
