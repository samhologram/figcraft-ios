import SwiftUI
@preconcurrency import FigCraftKit

/// Pages and the flattened layer tree of the current page: tap selects, the eye and lock toggles edit
/// `visible` / `locked`, a long press opens the Object and Arrange commands.
struct LayersPanel: View {
    let model: EditorModel

    @State private var collapsed: Set<UInt64> = []
    @State private var pagesOpen = true
    @State private var renamingPage: PageInfo?
    @State private var pageName = ""
    @State private var filter = ""

    private static let contextCommands: [[String]] = [
        ["edit.duplicate", "edit.delete"],
        ["object.group", "object.ungroup", "object.frameSelection", "object.mask", "component.create"],
        ["arrange.front", "arrange.forward", "arrange.backward", "arrange.back"],
        ["object.toggleVisible", "object.toggleLock"],
    ]

    var body: some View {
        VStack(spacing: 0) {
            pagesSection
            Divider()
            filterField
            layerList
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layers.panel")
        .alert("Rename page", isPresented: Binding(get: { renamingPage != nil }, set: { if !$0 { renamingPage = nil } })) {
            TextField("Name", text: $pageName)
            Button("Cancel", role: .cancel) { renamingPage = nil }
            Button("Rename") {
                if let page = renamingPage { model.run("page.rename", ["id": page.id, "name": pageName]) }
                renamingPage = nil
            }
        }
    }

    // MARK: Pages

    private var pagesSection: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { pagesOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: pagesOpen ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold))
                        Text("Pages").font(.footnote.weight(.semibold)).textCase(.uppercase)
                    }
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pages.toggle")
                Spacer()
                Menu {
                    pageActions(for: model.pages.first { $0.id == model.state.page })
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Page actions")
                .accessibilityIdentifier("pages.menu")
                IconButton(symbol: "plus", label: "Add page", identifier: "command.page.add") {
                    model.run("page.add")
                }
            }
            .padding(.horizontal, 14)
            if pagesOpen {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.pages, id: \.id) { page in pageRow(page) }
                    }
                }
                .frame(maxHeight: min(CGFloat(max(model.pages.count, 1)) * 40, 160))
                .accessibilityIdentifier("pages.list")
            }
        }
    }

    @ViewBuilder
    private func pageRow(_ page: PageInfo) -> some View {
        if page.isDivider {
            Divider().padding(.horizontal, 14).padding(.vertical, 8)
        } else {
            let current = page.id == model.state.page
            Button {
                model.run("page.select", ["id": page.id])
            } label: {
                HStack {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(verbatim: page.name).lineLimit(1)
                    Spacer(minLength: 0)
                    if current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .background(current ? Color.accentColor.opacity(0.12) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("page.\(page.id)")
            .accessibilityAddTraits(current ? .isSelected : [])
            .contextMenu { pageActions(for: page) }
        }
    }

    /// Rename, duplicate and delete a page (the page menu button and the row's context menu).
    @ViewBuilder
    private func pageActions(for page: PageInfo?) -> some View {
        if let page {
            Button("Rename\u{2026}", systemImage: "pencil") {
                pageName = page.name
                renamingPage = page
            }
            .accessibilityIdentifier("command.page.rename")
            Button("Duplicate", systemImage: "plus.square.on.square") { model.run("page.duplicate", ["id": page.id]) }
                .accessibilityIdentifier("command.page.duplicate")
            Button("Delete", systemImage: "trash", role: .destructive) { model.run("page.delete", ["id": page.id]) }
                .disabled(model.pages.filter { !$0.isDivider }.count < 2)
                .accessibilityIdentifier("command.page.delete")
        }
    }

    // MARK: Layers

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter layers", text: $filter)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("layers.filter")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var visibleRows: [LayerRow] {
        let byID = Dictionary(model.layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let term = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return model.layers.filter { row in
            if !term.isEmpty { return row.name.lowercased().contains(term) }
            var parent = row.parent
            var hops = 0
            while let p = parent, hops < 64 {
                if collapsed.contains(p) { return false }
                parent = byID[p]?.parent
                hops += 1
            }
            return true
        }
    }

    private var layerList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let rows = visibleRows
                if rows.isEmpty {
                    Text(filter.isEmpty ? "No layers on this page." : "No layers match.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
                ForEach(rows, id: \.id) { row in layerRow(row) }
            }
        }
        .accessibilityIdentifier("layers.list")
    }

    private func layerRow(_ row: LayerRow) -> some View {
        let filtering = !filter.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                Color.clear.frame(width: filtering ? 0 : CGFloat(min(row.depth, 12)) * 14, height: 1)
                if row.hasChildren && !filtering {
                    Button {
                        if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
                    } label: {
                        Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(collapsed.contains(row.id) ? "Expand" : "Collapse")
                    .accessibilityIdentifier("layer.\(row.id).disclosure")
                } else {
                    Color.clear.frame(width: 22, height: 1)
                }
                Button {
                    model.select([row.id])
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Symbols.layerKind(row.kind))
                            .frame(width: 20)
                            .foregroundStyle(row.selected ? Color.accentColor : .secondary)
                        Text(verbatim: row.name.isEmpty ? Humanize.key(row.kind) : row.name)
                            .lineLimit(1)
                            .foregroundStyle(row.visible ? Color.primary : Color.secondary)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("layer.\(row.id)")
                .accessibilityLabel(row.name.isEmpty ? Humanize.key(row.kind) : row.name)
                .accessibilityAddTraits(row.selected ? .isSelected : [])
            }
            toggle(symbol: row.locked ? "lock.fill" : "lock.open", shown: row.locked, label: row.locked ? "Unlock" : "Lock",
                   id: "layer.\(row.id).locked") { setFlag(row, "locked", !row.locked) }
            toggle(symbol: row.visible ? "eye" : "eye.slash", shown: !row.visible, label: row.visible ? "Hide" : "Show",
                   id: "layer.\(row.id).visible") { setFlag(row, "visible", !row.visible) }
        }
        .padding(.leading, 8)
        .background(row.selected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contextMenu { contextMenu(for: row) }
    }

    private func toggle(symbol: String, shown: Bool, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(shown ? Color.primary : Color.secondary.opacity(0.45))
                .frame(width: 32, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func setFlag(_ row: LayerRow, _ key: String, _ value: Bool) {
        model.run("node.set", ["ids": [row.id], "props": [key: value]])
    }

    @ViewBuilder
    private func contextMenu(for row: LayerRow) -> some View {
        Button("Rename\u{2026}", systemImage: "pencil") { model.renameLayerID = row.id }
            .accessibilityIdentifier("layer.\(row.id).rename")
        ForEach(Array(Self.contextCommands.enumerated()), id: \.offset) { _, group in
            Divider()
            ForEach(group, id: \.self) { id in
                Button(CommandCatalog.shared.label(id)) {
                    if !row.selected { model.select([row.id]) }
                    model.run(id)
                }
                .disabled(!CommandCatalog.shared.isKnown(id))
                .accessibilityIdentifier("command.\(id)")
            }
        }
    }
}
