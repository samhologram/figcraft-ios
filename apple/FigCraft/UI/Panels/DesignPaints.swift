import SwiftUI
@preconcurrency import FigCraftKit

/// A colour well. Picking is debounced (one undo step per pause, not per frame of the picker).
struct PaintSwatch: View {
    let hex: String
    let commit: (String) -> Void

    @State private var color: Color = .gray
    @State private var pending: Task<Void, Never>?

    var body: some View {
        ColorPicker("Colour", selection: $color, supportsOpacity: false)
            .labelsHidden()
            .onAppear { color = Color(hex: hex) ?? .gray }
            .onChange(of: hex) { _, new in
                if let c = Color(hex: new), c.hexString().lowercased() != color.hexString().lowercased() { color = c }
            }
            .onChange(of: color) { _, new in
                let picked = new.hexString()
                guard picked.lowercased() != String(hex.prefix(7)).lowercased() else { return }
                pending?.cancel()
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    if !Task.isCancelled { commit(picked) }
                }
            }
            .accessibilityIdentifier("swatch")
    }
}

// MARK: Fill and stroke

struct PaintSection: View {
    let model: EditorModel
    let json: JSONObject
    let fills: Bool

    private static let aligns: [OptionRow.Option] = [
        .init(value: "inside", label: "Inside"), .init(value: "center", label: "Center"), .init(value: "outside", label: "Outside"),
    ]

    private var paints: [JSONObject] { json.objects(fills ? "fills" : "strokes") }
    private var name: String { fills ? "fill" : "stroke" }

    var body: some View {
        InspectorSection(name, title: fills ? "Fill" : "Stroke") {
            IconButton(symbol: "plus", label: fills ? "Add fill" : "Add stroke",
                       identifier: fills ? "command.fill.add" : "command.stroke.add") {
                model.run(fills ? "fill.add" : "stroke.add")
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                let list = paints
                if list.isEmpty {
                    Text(fills ? "No fills." : "No strokes.").font(.footnote).foregroundStyle(.tertiary)
                }
                ForEach(Array(list.enumerated()), id: \.offset) { index, paint in
                    row(index: index, paint: paint)
                }
                if !fills && !list.isEmpty {
                    FieldRow {
                        ScrubField(model: model, key: "strokeWeight", label: "Weight", value: json.number("strokeWeight"), step: 0.1, range: 0...10_000)
                        MenuPicker(key: "strokeAlign", title: "", options: Self.aligns, selected: json.string("strokeAlign")) { v in
                            model.setProps(["strokeAlign": v])
                        }
                    }
                }
            }
        }
    }

    private func key(_ index: Int, _ suffix: String = "") -> String {
        (index == 0 ? name : "\(name).\(index)") + suffix
    }

    @ViewBuilder
    private func row(index: Int, paint: JSONObject) -> some View {
        let type = paint.string("type") ?? "solid"
        let visible = paint.bool("visible") ?? true
        let setCommand = fills ? "fill.set" : "stroke.set"
        HStack(spacing: 6) {
            Button {
                model.run(setCommand, ["index": index, "visible": !visible])
            } label: {
                Image(systemName: visible ? "eye" : "eye.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(visible ? Color.primary : Color.secondary)
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(visible ? "Hide" : "Show")
            .accessibilityIdentifier("control.\(key(index, ".visible"))")
            if type == "solid", let hex = paint.string("color") {
                PaintSwatch(hex: hex) { picked in model.run(setCommand, ["index": index, "color": picked]) }
                    .frame(width: 34)
                CommitTextField(key: key(index), placeholder: "#RRGGBB", value: String(hex.prefix(7)).uppercased()) { text in
                    model.run(setCommand, ["index": index, "color": text])
                }
                ScrubField(model: model, key: key(index, ".opacity"), label: "%", value: paint.number("opacity") ?? 1,
                           scale: 100, step: 0.5, range: 0...100, decimals: 0) { v in
                    model.run(setCommand, ["index": index, "opacity": v])
                }
                .frame(width: 84)
            } else {
                Text(verbatim: Humanize.key(type))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("control.\(key(index))")
            }
            IconButton(symbol: "minus", label: "Remove", identifier: fills ? "command.fill.remove" : "command.stroke.remove") {
                model.run(fills ? "fill.remove" : "stroke.remove", ["index": index])
            }
        }
    }
}

// MARK: Effects

struct EffectsSection: View {
    let model: EditorModel
    let json: JSONObject

    private struct EffectType: Identifiable {
        let value: String
        let label: String
        var id: String { value }
    }

    private static let types: [EffectType] = [
        EffectType(value: "dropShadow", label: "Drop shadow"), EffectType(value: "innerShadow", label: "Inner shadow"),
        EffectType(value: "layerBlur", label: "Layer blur"), EffectType(value: "backgroundBlur", label: "Background blur"),
        EffectType(value: "noise", label: "Noise"), EffectType(value: "texture", label: "Texture"),
        EffectType(value: "glass", label: "Glass"),
    ]

    private var effects: [JSONObject] { json.objects("effects") }

    /// Writes the whole effect list back (the engine reads the camelCase form `node.get` writes).
    private func write(_ mutate: (inout [JSONObject]) -> Void) {
        var list = effects
        mutate(&list)
        model.setProps(["effects": list])
    }

    var body: some View {
        InspectorSection("effects", title: "Effects") {
            Menu {
                ForEach(Self.types) { type in
                    Button(type.label) { model.run("effect.add", ["type": type.value]) }
                        .accessibilityIdentifier("command.effect.add")
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 36, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Add effect")
            .accessibilityIdentifier("effects.add")
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                let list = effects
                if list.isEmpty { Text("No effects.").font(.footnote).foregroundStyle(.tertiary) }
                ForEach(Array(list.enumerated()), id: \.offset) { index, effect in
                    effectRow(index: index, effect: effect)
                }
            }
        }
    }

    @ViewBuilder
    private func effectRow(index: Int, effect: JSONObject) -> some View {
        let type = effect.string("type") ?? ""
        let visible = effect.bool("visible") ?? true
        let shadow = type == "dropShadow" || type == "innerShadow"
        let offset = effect.numbers("offset")
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    write { $0[safe: index]?["visible"] = !visible }
                } label: {
                    Image(systemName: visible ? "eye" : "eye.slash")
                        .font(.system(size: 13))
                        .foregroundStyle(visible ? Color.primary : Color.secondary)
                        .frame(width: 30, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(visible ? "Hide effect" : "Show effect")
                .accessibilityIdentifier("control.effects.\(index).visible")
                Text(verbatim: Self.types.first { $0.value == type }?.label ?? Humanize.key(type))
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconButton(symbol: "minus", label: "Remove effect", identifier: "command.effect.remove") {
                    model.run("effect.remove", ["index": index])
                }
            }
            if effect.number("radius") != nil || shadow {
                FieldRow {
                    ScrubField(model: model, key: "effects.\(index).radius", label: "Blur", value: effect.number("radius") ?? 0,
                               step: 0.2, range: 0...10_000) { v in write { $0[safe: index]?["radius"] = v } }
                    if shadow {
                        ScrubField(model: model, key: "effects.\(index).spread", label: "Spread", value: effect.number("spread") ?? 0,
                                   step: 0.2) { v in write { $0[safe: index]?["spread"] = v } }
                    }
                }
            }
            if shadow {
                FieldRow {
                    ScrubField(model: model, key: "effects.\(index).x", label: "X", value: offset.first ?? 0) { v in
                        write { $0[safe: index]?["offset"] = [v, offset.count > 1 ? offset[1] : 0] }
                    }
                    ScrubField(model: model, key: "effects.\(index).y", label: "Y", value: offset.count > 1 ? offset[1] : 0) { v in
                        write { $0[safe: index]?["offset"] = [offset.first ?? 0, v] }
                    }
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension Array {
    /// Bounds-checked access that can be mutated through (`list[safe: i]?["k"] = v`).
    subscript(safe index: Int) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            guard indices.contains(index), let newValue else { return }
            self[index] = newValue
        }
    }
}

// MARK: Layout grids (frames)

struct GridsSection: View {
    let model: EditorModel
    let json: JSONObject

    private struct GridKind: Identifiable {
        let value: String
        let label: String
        var id: String { value }
    }

    private static let kinds: [GridKind] = [
        GridKind(value: "grid", label: "Grid"), GridKind(value: "columns", label: "Columns"), GridKind(value: "rows", label: "Rows"),
    ]

    var body: some View {
        InspectorSection("grids", title: "Layout grid") {
            Menu {
                ForEach(Self.kinds) { kind in
                    Button(kind.label) { model.run("grid.add", ["grid": ["kind": kind.value]]) }
                        .accessibilityIdentifier("command.grid.add")
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 36, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Add layout grid")
            .accessibilityIdentifier("grids.add")
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                let grids = json.objects("grids")
                if grids.isEmpty { Text("No layout grids.").font(.footnote).foregroundStyle(.tertiary) }
                ForEach(Array(grids.enumerated()), id: \.offset) { index, grid in
                    HStack {
                        Text(verbatim: summary(grid)).font(.callout).lineLimit(1)
                        Spacer()
                        IconButton(symbol: "minus", label: "Remove layout grid", identifier: "command.grid.remove") {
                            model.run("grid.remove", ["index": index])
                        }
                    }
                }
            }
        }
    }

    private func summary(_ grid: JSONObject) -> String {
        let kind = grid.string("kind") ?? "grid"
        switch kind {
        case "grid": return "Grid \(Humanize.number(grid.number("size") ?? 10)) px"
        default:
            let count = Int(grid.number("count") ?? 0)
            return "\(Humanize.key(kind)) \(count == 0 ? "auto" : String(count)), gutter \(Humanize.number(grid.number("gutter") ?? 0))"
        }
    }
}

// MARK: Export

struct ExportSection: View {
    let model: EditorModel
    let json: JSONObject?

    private static let scales: [OptionRow.Option] = [0.5, 0.75, 1, 1.5, 2, 3, 4].map {
        OptionRow.Option(value: Humanize.number($0), label: "\(Humanize.number($0))x")
    }
    private static let formats: [OptionRow.Option] = ["png", "jpg", "svg", "pdf", "webp"].map {
        OptionRow.Option(value: $0, label: $0.uppercased())
    }

    var body: some View {
        InspectorSection("export", title: "Export") {
            if json != nil {
                IconButton(symbol: "plus", label: "Add export setting", identifier: "command.export.add") { model.run("export.add") }
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if let json {
                    let exports = json.objects("exports")
                    ForEach(Array(exports.enumerated()), id: \.offset) { index, setting in
                        row(index: index, setting: setting)
                    }
                }
                Button {
                    model.showExport = true
                } label: {
                    Label(json == nil ? "Export page\u{2026}" : "Export layer\u{2026}", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("export.open")
            }
        }
    }

    private func row(index: Int, setting: JSONObject) -> some View {
        let size = setting.object("size")
        let scale = (size?.string("by") == "scale") ? Humanize.number(size?.number("value") ?? 1) : nil
        return HStack(spacing: 6) {
            MenuPicker(key: "exports.\(index).size", title: "", options: Self.scales, selected: scale) { v in
                model.run("export.update", ["index": index, "size": "\(v)x"])
            }
            CommitTextField(key: "exports.\(index).suffix", placeholder: "Suffix", value: setting.string("suffix") ?? "") { text in
                model.run("export.update", ["index": index, "suffix": text])
            }
            MenuPicker(key: "exports.\(index).format", title: "", options: Self.formats, selected: setting.string("format")) { v in
                model.run("export.update", ["index": index, "format": v])
            }
            IconButton(symbol: "minus", label: "Remove export setting", identifier: "command.export.remove") {
                model.run("export.remove", ["index": index])
            }
        }
    }
}
