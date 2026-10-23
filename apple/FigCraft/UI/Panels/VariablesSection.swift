import SwiftUI
@preconcurrency import FigCraftKit

/// Local variables of the file (Assets tab): collections, modes and values. Pick a collection and a mode, edit a
/// variable's value in that mode, add or remove variables, collections and modes. Engine commands: `variable.list`
/// (query), `variable.createCollection`, `variable.renameCollection`, `variable.deleteCollection`,
/// `variable.addMode`, `variable.renameMode`, `variable.removeMode`, `variable.create`, `variable.update`,
/// `variable.set`, `variable.duplicate`, `variable.delete`. Identifier `section.variables`.
struct VariablesSection: View {
    let model: EditorModel

    private struct ModeItem: Identifiable {
        let id: String
        let name: String
    }

    private struct CollectionItem: Identifiable {
        let id: String
        let name: String
        let modes: [ModeItem]
        let editable: Bool
    }

    private struct VariableItem: Identifiable {
        let id: String
        let name: String
        let collection: String
        let type: String
        let values: JSONObject
    }

    private static let types: [OptionRow.Option] = [
        .init(value: "color", label: "Color"), .init(value: "number", label: "Number"),
        .init(value: "string", label: "String"), .init(value: "boolean", label: "Boolean"),
    ]

    @State private var collections: [CollectionItem] = []
    @State private var variables: [VariableItem] = []
    @State private var collectionID: String?
    @State private var modeID: String?
    @State private var request: NameRequest?

    private var collection: CollectionItem? {
        collections.first { $0.id == collectionID } ?? collections.first
    }

    private var mode: ModeItem? {
        guard let collection else { return nil }
        return collection.modes.first { $0.id == modeID } ?? collection.modes.first
    }

    private var shown: [VariableItem] {
        guard let collection else { return [] }
        return variables.filter { $0.collection == collection.id }
    }

    var body: some View {
        InspectorSection("variables", title: "Variables") {
            headerMenu
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if collections.isEmpty {
                    Text("No variables yet. Create a collection to start.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("variables.empty")
                } else {
                    pickers
                    let list = shown
                    if list.isEmpty {
                        Text("This collection has no variables. Use + to add one.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(list) { variable in variableRow(variable) }
                }
            }
        }
        .onChange(of: model.state.revision, initial: true) { _, _ in reload() }
        .namePrompt($request) { request, text in confirm(request, text) }
    }

    // MARK: Header

    private var headerMenu: some View {
        Menu {
            Button("New collection\u{2026}", systemImage: "folder.badge.plus") {
                request = NameRequest(kind: "newCollection", title: "New collection", initial: "Collection", confirmLabel: "Create")
            }
            .accessibilityIdentifier("variables.newCollection")
            if let collection {
                Divider()
                Menu("New variable", systemImage: "plus") {
                    ForEach(Self.types) { type in
                        Button(type.label) { addVariable(type: type.value, in: collection) }
                            .accessibilityIdentifier("variables.new.\(type.value)")
                    }
                }
                Divider()
                Button("Rename collection\u{2026}", systemImage: "pencil") {
                    request = NameRequest(kind: "renameCollection", title: "Rename collection", initial: collection.name,
                                          target: collection.id, confirmLabel: "Rename")
                }
                Button("Delete collection", systemImage: "trash", role: .destructive) {
                    model.run("variable.deleteCollection", ["collection": collection.id])
                    collectionID = nil
                    modeID = nil
                }
                if collection.editable {
                    Divider()
                    Button("Add mode\u{2026}", systemImage: "rectangle.badge.plus") {
                        request = NameRequest(kind: "addMode", title: "Add mode", initial: "Mode \(collection.modes.count + 1)",
                                              target: collection.id, confirmLabel: "Add")
                    }
                    if let mode {
                        Button("Rename mode\u{2026}", systemImage: "pencil") {
                            request = NameRequest(kind: "renameMode", title: "Rename mode", initial: mode.name,
                                                  target: mode.id, confirmLabel: "Rename")
                        }
                        Button("Delete mode", systemImage: "trash", role: .destructive) {
                            model.run("variable.removeMode", ["collection": collection.id, "mode": mode.id])
                            modeID = nil
                        }
                        .disabled(collection.modes.count < 2)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Variable actions")
        .accessibilityIdentifier("variables.menu")
    }

    private var pickers: some View {
        FieldRow {
            MenuPicker(key: "variableCollection", title: "", options: collections.map { OptionRow.Option(value: $0.id, label: $0.name) },
                       selected: collection?.id) { value in
                collectionID = value
                modeID = nil
            }
            if let collection, collection.modes.count > 1 {
                MenuPicker(key: "variableMode", title: "", options: collection.modes.map { OptionRow.Option(value: $0.id, label: $0.name) },
                           selected: mode?.id) { value in modeID = value }
            }
        }
    }

    // MARK: Variable rows

    private func variableRow(_ variable: VariableItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CommitTextField(key: "variable.\(variable.id).name", placeholder: "Name", value: variable.name) { name in
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { model.run("variable.update", ["variable": variable.id, "name": trimmed]) }
                }
                Menu {
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        model.run("variable.duplicate", ["variable": variable.id])
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        model.run("variable.delete", ["variable": variable.id])
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 34, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Variable actions")
                .accessibilityIdentifier("variable.\(variable.id).menu")
            }
            valueEditor(variable)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("variable.\(variable.id)")
    }

    @ViewBuilder
    private func valueEditor(_ variable: VariableItem) -> some View {
        let modeKey = mode?.id ?? ""
        let entry = variable.values.object(modeKey) ?? variable.values.values.compactMap { $0 as? JSONObject }.first ?? [:]
        let raw = entry["value"]
        let key = "variable.\(variable.id).value"
        if entry.string("type") == "alias" {
            let target = (raw as? String).flatMap { id in variables.first { $0.id == id }?.name } ?? "variable"
            Label(target, systemImage: "link")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("control.\(key)")
        } else {
            switch variable.type {
            case "color":
                let hex = EngineColor.hex(raw) ?? "#000000"
                HStack(spacing: 10) {
                    PaintSwatch(hex: hex) { picked in setValue(variable, picked) }
                        .frame(width: 34)
                    CommitTextField(key: key, placeholder: "#RRGGBB", value: hex.uppercased()) { text in
                        guard let parsed = EngineColor.parse(text) else {
                            model.showToast("Invalid color")
                            return
                        }
                        setValue(variable, parsed.hex)
                    }
                }
            case "number":
                let number = (raw as? NSNumber)?.doubleValue ?? 0
                CommitTextField(key: key, placeholder: "Number", value: Humanize.number(number, decimals: 4)) { text in
                    let cleaned = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
                    if let v = Double(cleaned), v.isFinite { setValue(variable, v) } else { model.showToast("Invalid number") }
                }
            case "boolean":
                SwitchRow(key: key, title: "Value", isOn: (raw as? NSNumber)?.boolValue ?? false) { on in setValue(variable, on) }
            default:
                CommitTextField(key: key, placeholder: "Text", value: (raw as? String) ?? "") { text in setValue(variable, text) }
            }
        }
    }

    // MARK: Engine

    private func setValue(_ variable: VariableItem, _ value: Any) {
        var params: [String: Any] = ["variable": variable.id, "value": value]
        if let mode { params["mode"] = mode.id }
        model.run("variable.set", params)
    }

    private func addVariable(type: String, in collection: CollectionItem) {
        let initial: Any
        switch type {
        case "color": initial = "#000000"
        case "number": initial = 0
        case "boolean": initial = true
        default: initial = ""
        }
        let count = variables.filter { $0.collection == collection.id }.count + 1
        let label = Self.types.first { $0.value == type }?.label ?? "Variable"
        model.run("variable.create", ["collection": collection.id, "name": "\(label) \(count)", "type": type, "value": initial])
    }

    private func confirm(_ request: NameRequest, _ text: String) {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch request.kind {
        case "newCollection":
            if let result = model.run("variable.createCollection", ["name": name]) as? JSONObject, let id = result.string("id") {
                collectionID = id
                modeID = nil
            }
        case "renameCollection":
            model.run("variable.renameCollection", ["collection": request.target, "name": name])
        case "addMode":
            if let result = model.run("variable.addMode", ["collection": request.target, "name": name]) as? JSONObject,
               let id = result.string("id") {
                modeID = id
            }
        case "renameMode":
            if let collection {
                model.run("variable.renameMode", ["collection": collection.id, "mode": request.target, "name": name])
            }
        default:
            break
        }
    }

    private func reload() {
        let result = model.query("variable.list") as? JSONObject
        collections = (result?.objects("collections") ?? []).compactMap { item -> CollectionItem? in
            guard let id = item.string("id") else { return nil }
            let modes = item.objects("modes").compactMap { mode -> ModeItem? in
                guard let modeID = mode.string("id") else { return nil }
                return ModeItem(id: modeID, name: mode.string("name") ?? "Mode")
            }
            // A collection that extends a library one has the library's modes: they are not editable here.
            return CollectionItem(id: id, name: item.string("name") ?? "Collection", modes: modes, editable: item["extends"] == nil)
        }
        variables = (result?.objects("variables") ?? []).compactMap { item -> VariableItem? in
            guard let id = item.string("id") else { return nil }
            return VariableItem(id: id, name: item.string("name") ?? "Variable", collection: item.string("collection") ?? "",
                                type: item.string("resolvedType") ?? "string", values: item.object("values") ?? [:])
        }
        if let current = collectionID, !collections.contains(where: { $0.id == current }) {
            collectionID = nil
            modeID = nil
        }
    }
}
