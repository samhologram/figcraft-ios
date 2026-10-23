import SwiftUI
@preconcurrency import FigCraftKit

/// Local styles of the file (Assets tab): colour, text, effect and grid styles. Tap applies a style to the
/// selection; the row menu renames, redefines from the selection, duplicates or deletes it. Engine commands:
/// `style.list` (query), `style.create`, `style.apply`, `style.update`, `style.duplicate`, `style.delete`.
/// Identifier `section.styles`.
struct StylesSection: View {
    let model: EditorModel

    private struct StyleRow: Identifiable {
        let id: String
        let name: String
        let type: String
        let swatchHex: String?
        let detail: String
    }

    private struct Kind: Identifiable {
        let type: String
        let title: String
        let symbol: String
        var id: String { type }
    }

    private static let kinds: [Kind] = [
        Kind(type: "paint", title: "Color styles", symbol: "paintpalette"),
        Kind(type: "text", title: "Text styles", symbol: "textformat"),
        Kind(type: "effect", title: "Effect styles", symbol: "sparkles"),
        Kind(type: "grid", title: "Grid styles", symbol: "grid"),
    ]

    @State private var rows: [StyleRow] = []
    @State private var request: NameRequest?

    private var hasSelection: Bool { !model.state.selection.isEmpty }

    var body: some View {
        InspectorSection("styles", title: "Styles") {
            Menu {
                ForEach(Self.kinds) { kind in
                    Button {
                        request = NameRequest(kind: "create", title: "New \(kind.title.lowercased().dropLast()) from selection",
                                              initial: "Style", target: kind.type, confirmLabel: "Create")
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                    .disabled(!hasSelection)
                    .accessibilityIdentifier("styles.create.\(kind.type)")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Create style from selection")
            .accessibilityIdentifier("styles.add")
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                if rows.isEmpty {
                    Text("No styles yet. Select a layer, then use + to save its fill, text or effects as a style.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("styles.empty")
                }
                ForEach(Self.kinds) { kind in
                    let group = rows.filter { $0.type == kind.type }
                    if !group.isEmpty {
                        SubLabel(kind.title)
                            .padding(.top, 6)
                        ForEach(group) { row in styleRow(row, symbol: kind.symbol) }
                    }
                }
            }
        }
        .onChange(of: model.state.revision, initial: true) { _, _ in reload() }
        .namePrompt($request) { request, text in
            let name = text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            switch request.kind {
            case "create":
                model.run("style.create", ["type": request.target, "name": name])
            case "rename":
                model.run("style.update", ["style": request.target, "name": name])
            default:
                break
            }
        }
    }

    // MARK: Rows

    private func styleRow(_ row: StyleRow, symbol: String) -> some View {
        HStack(spacing: 0) {
            Button {
                model.run("style.apply", ["style": row.id])
            } label: {
                HStack(spacing: 10) {
                    preview(row, symbol: symbol)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: row.name).lineLimit(1)
                        if !row.detail.isEmpty {
                            Text(verbatim: row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasSelection)
            .opacity(hasSelection ? 1 : 0.6)
            .accessibilityLabel("Apply \(row.name)")
            .accessibilityIdentifier("style.\(row.id)")
            Menu {
                Button("Apply to selection", systemImage: "checkmark.circle") {
                    model.run("style.apply", ["style": row.id])
                }
                .disabled(!hasSelection)
                Button("Rename\u{2026}", systemImage: "pencil") {
                    request = NameRequest(kind: "rename", title: "Rename style", initial: row.name, target: row.id, confirmLabel: "Rename")
                }
                Button("Update from selection", systemImage: "arrow.triangle.2.circlepath") {
                    if let id = model.state.selection.first { model.run("style.update", ["style": row.id, "from": id]) }
                }
                .disabled(!hasSelection)
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    model.run("style.duplicate", ["style": row.id])
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    model.run("style.delete", ["style": row.id])
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Style actions")
            .accessibilityIdentifier("style.\(row.id).menu")
        }
    }

    @ViewBuilder
    private func preview(_ row: StyleRow, symbol: String) -> some View {
        if let hex = row.swatchHex, let color = Color(hex: hex) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }

    // MARK: Engine

    private func reload() {
        let list = (model.query("style.list") as? [Any])?.compactMap { $0 as? JSONObject } ?? []
        rows = list.compactMap { item -> StyleRow? in
            guard let id = item.string("id") else { return nil }
            let type = item.string("type") ?? "paint"
            var swatch: String?
            var detail = item.string("description") ?? ""
            if type == "paint" {
                let first = item.objects("paints").first
                if let first, (first.string("type") ?? "solid") == "solid" { swatch = EngineColor.hex(first["color"]) }
                if first != nil, swatch == nil { detail = detail.isEmpty ? "Gradient" : detail }
            }
            return StyleRow(id: id, name: item.string("name") ?? "Style", type: type, swatchHex: swatch, detail: detail)
        }
    }
}
