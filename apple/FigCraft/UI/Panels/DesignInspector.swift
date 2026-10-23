import SwiftUI
@preconcurrency import FigCraftKit

/// The Design tab. Sections appear under the same conditions as on the desktop (`right.rs` `fn design`): the page
/// section when nothing is selected; for a layer the header, position, layout / auto layout, appearance, text
/// (text layers only), fill, stroke, effects, layout grids (frames) and export.
struct DesignInspector: View {
    let model: EditorModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                let selection = model.state.selection
                if selection.isEmpty {
                    PageSection(model: model)
                } else if let json = model.selectionJSON {
                    LayerSections(model: model, json: json)
                } else {
                    MultiSelectionSections(model: model, count: selection.count)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("design.scroll")
    }
}

// MARK: Page (nothing selected)

private struct PageSection: View {
    let model: EditorModel

    var body: some View {
        let page = model.nodeObject(model.state.page)
        let background = page?.string("background") ?? "#E5E5E5"
        InspectorSection("page", title: "Page") {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: model.pages.first { $0.id == model.state.page }?.name ?? "Page")
                    .font(.headline)
                    .accessibilityIdentifier("page.name")
                SubLabel("Background")
                HStack(spacing: 10) {
                    PaintSwatch(hex: background) { hex in model.run("page.setBackground", ["color": hex]) }
                    CommitTextField(key: "pageBackground", placeholder: "#RRGGBB", value: background) { text in
                        model.run("page.setBackground", ["color": text])
                    }
                }
                Text("Select a layer to edit its properties.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        Divider()
        ExportSection(model: model, json: nil)
    }
}

// MARK: Several layers

private struct MultiSelectionSections: View {
    let model: EditorModel
    let count: Int

    var body: some View {
        InspectorSection("position", title: "\(count) layers") {
            VStack(alignment: .leading, spacing: 10) {
                AlignmentRow(model: model)
                if count > 2 {
                    HStack(spacing: 8) {
                        commandButton("distribute.horizontal", symbol: "arrow.left.and.right")
                        commandButton("distribute.vertical", symbol: "arrow.up.and.down")
                        commandButton("arrange.tidy", symbol: "square.grid.2x2")
                    }
                }
                HStack(spacing: 8) {
                    commandButton("object.group", symbol: "square.on.square")
                    commandButton("object.frameSelection", symbol: "number.square")
                    commandButton("object.mask", symbol: "circle.lefthalf.filled")
                    commandButton("component.create", symbol: "diamond")
                }
                Text("Select a single layer to edit its fields.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        SelectionColorsSection(model: model)
    }

    private func commandButton(_ id: String, symbol: String) -> some View {
        Button { model.run(id) } label: {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!model.isEnabled(id))
        .accessibilityLabel(CommandCatalog.shared.label(id))
        .accessibilityIdentifier("command.\(id)")
    }
}

// MARK: One layer

private struct LayerSections: View {
    let model: EditorModel
    let json: JSONObject

    private var type: String { json.string("type") ?? "" }
    private var isText: Bool { type == "TEXT" }
    private var isFrameLike: Bool { ["FRAME", "COMPONENT", "COMPONENT_SET", "INSTANCE", "SECTION"].contains(type) }
    private var hasCorners: Bool { ["RECTANGLE", "FRAME", "COMPONENT", "COMPONENT_SET", "INSTANCE"].contains(type) }

    var body: some View {
        // Grouped so no builder passes ten children.
        Group {
            Group {
                HeaderSection(model: model, json: json)
                Divider()
                PositionSection(model: model, json: json)
                Divider()
                LayoutSection(model: model, json: json, frameLike: isFrameLike)
                Divider()
                AppearanceSection(model: model, json: json, hasCorners: hasCorners)
            }
            Group {
                if isText {
                    Divider()
                    TextSection(model: model, json: json)
                }
                Divider()
                PaintSection(model: model, json: json, fills: true)
                Divider()
                PaintSection(model: model, json: json, fills: false)
            }
            Group {
                Divider()
                EffectsSection(model: model, json: json)
                SelectionColorsSection(model: model)
                if isFrameLike {
                    Divider()
                    GridsSection(model: model, json: json)
                }
                Divider()
                ExportSection(model: model, json: json)
            }
        }
    }
}

// MARK: Header

private struct HeaderSection: View {
    let model: EditorModel
    let json: JSONObject

    var body: some View {
        let type = json.string("type") ?? ""
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: Humanize.nodeType(type))
                    .font(.headline)
                    .accessibilityIdentifier("header.type")
                Spacer()
                if type == "FRAME" {
                    headerButton("frame.swapOrientation", symbol: "rectangle.portrait.rotate")
                }
                if type == "GROUP" {
                    headerButton("object.convertToFrame", symbol: "number.square")
                } else if type == "FRAME" {
                    headerButton("object.convertToGroup", symbol: "square.on.square")
                }
                headerButton("component.create", symbol: "diamond")
                headerButton("object.mask", symbol: "circle.lefthalf.filled")
                Menu {
                    ForEach(["bool.union", "bool.subtract", "bool.intersect", "bool.exclude", "vector.flatten"], id: \.self) { id in
                        Button(CommandCatalog.shared.label(id)) { model.run(id) }
                            .disabled(!model.isEnabled(id))
                            .accessibilityIdentifier("command.\(id)")
                    }
                } label: {
                    Image(systemName: "square.on.circle")
                        .frame(width: 34, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Boolean groups")
                .accessibilityIdentifier("header.boolean")
            }
            CommitTextField(key: "name", placeholder: "Layer name", value: json.string("name") ?? "") { name in
                model.setProps(["name": name])
            }
            if let component = json.string("mainComponentName") {
                Label("Instance of \(component)", systemImage: "diamond")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.header")
    }

    private func headerButton(_ id: String, symbol: String) -> some View {
        Button { model.run(id) } label: {
            Image(systemName: symbol)
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isEnabled(id))
        .opacity(model.isEnabled(id) ? 1 : 0.35)
        .accessibilityLabel(CommandCatalog.shared.label(id))
        .accessibilityIdentifier("command.\(id)")
    }
}

// MARK: Position

struct AlignmentRow: View {
    let model: EditorModel

    private struct AlignItem: Identifiable {
        let id: String
        let symbol: String
    }

    private static let items: [AlignItem] = [
        AlignItem(id: "align.left", symbol: "align.horizontal.left"), AlignItem(id: "align.hcenter", symbol: "align.horizontal.center"),
        AlignItem(id: "align.right", symbol: "align.horizontal.right"), AlignItem(id: "align.top", symbol: "align.vertical.top"),
        AlignItem(id: "align.vcenter", symbol: "align.vertical.center"), AlignItem(id: "align.bottom", symbol: "align.vertical.bottom"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.items) { item in
                let enabled = model.isEnabled(item.id)
                Button { model.run(item.id) } label: {
                    Image(systemName: item.symbol)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
                .accessibilityLabel(CommandCatalog.shared.label(item.id))
                .accessibilityIdentifier("command.\(item.id)")
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct PositionSection: View {
    let model: EditorModel
    let json: JSONObject

    private static let horizontal: [OptionRow.Option] = [
        .init(value: "left", label: "Left"), .init(value: "right", label: "Right"), .init(value: "leftRight", label: "Left & right"),
        .init(value: "center", label: "Center"), .init(value: "scale", label: "Scale"),
    ]
    private static let vertical: [OptionRow.Option] = [
        .init(value: "top", label: "Top"), .init(value: "bottom", label: "Bottom"), .init(value: "topBottom", label: "Top & bottom"),
        .init(value: "center", label: "Center"), .init(value: "scale", label: "Scale"),
    ]

    var body: some View {
        InspectorSection("position", title: "Position") {
            VStack(alignment: .leading, spacing: 8) {
                AlignmentRow(model: model)
                FieldRow {
                    ScrubField(model: model, key: "x", label: "X", value: json.number("x"))
                    ScrubField(model: model, key: "y", label: "Y", value: json.number("y"))
                }
                FieldRow {
                    ScrubField(model: model, key: "rotation", label: "\u{21BB}", value: json.number("rotation") ?? 0, unit: "\u{00B0}", step: 0.5)
                    HStack(spacing: 2) {
                        flip("object.flipH", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        flip("object.flipV", symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                        flip("object.rotateRight", symbol: "rotate.right")
                    }
                    .frame(maxWidth: .infinity)
                }
                if let constraints = json.object("constraints") {
                    SubLabel("Constraints")
                    FieldRow {
                        MenuPicker(key: "constraints.horizontal", title: "H", options: Self.horizontal,
                                   selected: constraints.string("horizontal")) { v in
                            model.setProps(["constraints": ["horizontal": v]])
                        }
                        MenuPicker(key: "constraints.vertical", title: "V", options: Self.vertical,
                                   selected: constraints.string("vertical")) { v in
                            model.setProps(["constraints": ["vertical": v]])
                        }
                    }
                }
            }
        }
    }

    private func flip(_ id: String, symbol: String) -> some View {
        Button { model.run(id) } label: {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CommandCatalog.shared.label(id))
        .accessibilityIdentifier("command.\(id)")
    }
}

// MARK: Layout and auto layout

private struct LayoutSection: View {
    let model: EditorModel
    let json: JSONObject
    let frameLike: Bool

    private static let sizing: [OptionRow.Option] = [
        .init(value: "fixed", label: "Fixed"), .init(value: "hug", label: "Hug"), .init(value: "fill", label: "Fill"),
    ]
    private static let mainAlign: [OptionRow.Option] = [
        .init(value: "min", label: "Start"), .init(value: "center", label: "Center"), .init(value: "max", label: "End"),
        .init(value: "spaceBetween", label: "Space between"), .init(value: "spaceAround", label: "Space around"),
        .init(value: "spaceEvenly", label: "Space evenly"),
    ]
    private static let crossAlign: [OptionRow.Option] = [
        .init(value: "min", label: "Start"), .init(value: "center", label: "Center"), .init(value: "max", label: "End"),
        .init(value: "baseline", label: "Baseline"),
    ]

    var body: some View {
        let layout = json.object("layout")
        let hasLayout = layout != nil
        InspectorSection("layout", title: hasLayout ? "Auto layout" : "Layout") {
            if frameLike {
                if hasLayout {
                    IconButton(symbol: "minus", label: "Remove auto layout", identifier: "command.layout.remove") { model.run("layout.remove") }
                } else {
                    IconButton(symbol: "plus", label: "Add auto layout", identifier: "command.layout.add") { model.run("layout.add") }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                FieldRow {
                    ScrubField(model: model, key: "width", label: "W", value: json.number("width"))
                    ScrubField(model: model, key: "height", label: "H", value: json.number("height"))
                }
                if let sizing = json.object("sizing") {
                    FieldRow {
                        MenuPicker(key: "sizingH", title: "Width", options: Self.sizing, selected: sizing.string("horizontal")) { v in
                            model.setProps(["sizingH": v])
                        }
                        MenuPicker(key: "sizingV", title: "Height", options: Self.sizing, selected: sizing.string("vertical")) { v in
                            model.setProps(["sizingV": v])
                        }
                    }
                }
                if let layout { autoLayout(layout) }
                if frameLike {
                    SwitchRow(key: "clip", title: "Clip content", isOn: json.bool("clip") ?? false) { model.setProps(["clip": $0]) }
                }
            }
        }
    }

    @ViewBuilder
    private func autoLayout(_ layout: JSONObject) -> some View {
        let mode = layout.string("mode") ?? "horizontal"
        OptionRow(key: "layout", options: [
            .init(value: "vertical", label: "Vertical", symbol: "arrow.down"),
            .init(value: "horizontal", label: "Horizontal", symbol: "arrow.right"),
            .init(value: "grid", label: "Grid", symbol: "square.grid.3x3"),
        ], selected: mode) { v in model.setProps(["layout": v]) }
        if mode == "grid" {
            FieldRow {
                ScrubField(model: model, key: "gridColumns", label: "Cols", value: layout.number("gridColumns"), decimals: 0)
                ScrubField(model: model, key: "gridRows", label: "Rows", value: layout.number("gridRows"), decimals: 0)
            }
            FieldRow {
                ScrubField(model: model, key: "gap", label: "Col gap", value: layout.number("gap"))
                ScrubField(model: model, key: "crossGap", label: "Row gap", value: layout.number("crossGap"))
            }
        } else {
            FieldRow {
                ScrubField(model: model, key: "gap", label: "Gap", value: layout.number("gap"))
                if layout.bool("wrap") == true {
                    ScrubField(model: model, key: "crossGap", label: "Line gap", value: layout.number("crossGap"))
                }
            }
            FieldRow {
                MenuPicker(key: "mainAlign", title: "Main", options: Self.mainAlign, selected: layout.string("mainAlign")) { v in
                    model.setProps(["mainAlign": v])
                }
                MenuPicker(key: "crossAlign", title: "Cross", options: Self.crossAlign, selected: layout.string("crossAlign")) { v in
                    model.setProps(["crossAlign": v])
                }
            }
            SwitchRow(key: "wrap", title: "Wrap", isOn: layout.bool("wrap") ?? false) { model.setProps(["wrap": $0]) }
        }
        let padding = layout.numbers("padding")
        let sides = padding.count == 4 ? padding : [0, 0, 0, 0]
        SubLabel("Padding")
        FieldRow {
            ScrubField(model: model, key: "paddingTop", label: "T", value: sides[0])
            ScrubField(model: model, key: "paddingBottom", label: "B", value: sides[2])
        }
        FieldRow {
            ScrubField(model: model, key: "paddingLeft", label: "L", value: sides[3])
            ScrubField(model: model, key: "paddingRight", label: "R", value: sides[1])
        }
    }
}

// MARK: Appearance

private struct AppearanceSection: View {
    let model: EditorModel
    let json: JSONObject
    let hasCorners: Bool

    private static let blends: [OptionRow.Option] = [
        "passThrough", "normal", "darken", "multiply", "plusDarker", "colorBurn", "lighten", "screen", "plusLighter", "colorDodge",
        "overlay", "softLight", "hardLight", "difference", "exclusion", "hue", "saturation", "color", "luminosity",
    ].map { OptionRow.Option(value: $0, label: Humanize.key($0)) }

    var body: some View {
        InspectorSection("appearance", title: "Appearance") {
            VStack(alignment: .leading, spacing: 8) {
                FieldRow {
                    ScrubField(model: model, key: "opacity", label: "Opacity", value: json.number("opacity") ?? 1, unit: "%",
                               scale: 100, step: 0.5, range: 0...100, decimals: 0)
                    if hasCorners {
                        let radius = json.number("cornerRadius") ?? json.numbers("cornerRadius").first ?? 0
                        ScrubField(model: model, key: "cornerRadius", label: "Radius", value: radius, range: 0...100_000)
                    }
                }
                MenuPicker(key: "blend", title: "Blend", options: Self.blends, selected: json.string("blend") ?? "passThrough") { v in
                    model.setProps(["blend": v])
                }
            }
        }
    }
}

// MARK: Text (text layers only)

private struct TextSection: View {
    let model: EditorModel
    let json: JSONObject

    private static let aligns: [OptionRow.Option] = [
        .init(value: "left", label: "Left", symbol: "text.alignleft"), .init(value: "center", label: "Center", symbol: "text.aligncenter"),
        .init(value: "right", label: "Right", symbol: "text.alignright"), .init(value: "justified", label: "Justified", symbol: "text.justify"),
    ]

    var body: some View {
        InspectorSection("text", title: "Text") {
            VStack(alignment: .leading, spacing: 8) {
                CommitTextField(key: "characters", placeholder: "Text", value: json.string("characters") ?? "") { text in
                    model.setProps(["characters": text])
                }
                CommitTextField(key: "fontFamily", placeholder: "Font family", value: json.string("fontFamily") ?? "") { text in
                    model.setProps(["fontFamily": text])
                }
                FieldRow {
                    CommitTextField(key: "fontStyle", placeholder: "Style", value: json.string("fontStyle") ?? "") { text in
                        model.setProps(["fontStyle": text])
                    }
                    ScrubField(model: model, key: "fontSize", label: "Size", value: json.number("fontSize"), range: 1...2000)
                }
                FieldRow {
                    CommitTextField(key: "lineHeight", placeholder: "Line height", value: json.string("lineHeight") ?? "auto") { text in
                        model.setProps(["lineHeight": Self.lengthValue(text)])
                    }
                    CommitTextField(key: "letterSpacing", placeholder: "Letter spacing", value: json.string("letterSpacing") ?? "0") { text in
                        model.setProps(["letterSpacing": Self.lengthValue(text)])
                    }
                }
                OptionRow(key: "textAlign", options: Self.aligns, selected: json.string("textAlign")) { v in
                    model.setProps(["textAlign": v])
                }
            }
        }
    }

    /// "24" and "24px" are pixels, "150%" a percentage, "auto" stays text.
    private static func lengthValue(_ text: String) -> Any {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("%") || t.lowercased() == "auto" { return t }
        let numeric = t.lowercased().replacingOccurrences(of: "px", with: "")
        if let n = Double(numeric), n.isFinite { return n }
        return t
    }
}
