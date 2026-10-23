import SwiftUI
@preconcurrency import FigCraftKit

/// The components on the current page (layers of kind component / component set). Tap selects the component;
/// the plus button inserts an instance of it (`instance.create`).
struct AssetsPanel: View {
    let model: EditorModel

    @State private var filter = ""

    private var components: [LayerRow] {
        let term = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return model.layers.filter { row in
            guard row.kind == "component" || row.kind == "componentSet" else { return false }
            return term.isEmpty || row.name.lowercased().contains(term)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search components", text: $filter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("assets.filter")
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
            ScrollView {
                LazyVStack(spacing: 0) {
                    let rows = components
                    if rows.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "diamond").font(.largeTitle).foregroundStyle(.tertiary)
                            Text(filter.isEmpty ? "No components on this page." : "No components match.")
                                .font(.callout).foregroundStyle(.secondary)
                            if filter.isEmpty {
                                Text("Select layers and choose Create component to make one.")
                                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                            }
                        }
                        .padding(28)
                        .accessibilityIdentifier("assets.empty")
                    }
                    ForEach(rows, id: \.id) { row in assetRow(row) }
                    Divider().padding(.top, 8)
                    StylesSection(model: model)
                    Divider()
                    VariablesSection(model: model)
                }
                .padding(.bottom, 24)
            }
            .accessibilityIdentifier("assets.list")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assets.panel")
    }

    private func assetRow(_ row: LayerRow) -> some View {
        HStack(spacing: 0) {
            Button {
                model.select([row.id])
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: Symbols.layerKind(row.kind)).foregroundStyle(.purple).frame(width: 22)
                    Text(verbatim: row.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(row.selected ? Color.accentColor.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("asset.\(row.id)")
            IconButton(symbol: "plus.circle", label: "Insert instance of \(row.name)", identifier: "asset.\(row.id).insert") {
                model.run("instance.create", ["component": row.id])
            }
            .padding(.trailing, 6)
        }
    }
}
